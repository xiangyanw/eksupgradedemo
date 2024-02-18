#!/bin/bash

ACCOUNT_ID=`aws sts get-caller-identity --query 'Account' --output text`
EKS_CLUSTER_NAME="eks-upgrade-demo"
AWS_REGION="us-west-2"

if [[ ! -d ~/.bashrc.d/ ]]; then
  mkdir ~/.bashrc.d
fi

echo "export ACCOUNT_ID=\"$ACCOUNT_ID\"" > ~/.bashrc.d/envvars.bash
echo "export EKS_CLUSTER_NAME=\"$EKS_CLUSTER_NAME\"" >> ~/.bashrc.d/envvars.bash
echo "export AWS_REGION=\"$AWS_REGION\"" >> ~/.bashrc.d/envvars.bash
source ~/.bashrc.d/envvars.bash

WRK_DIR=`dirname $0`
cd ${WRK_DIR}

# Update kubectl version
curl -LO https://dl.k8s.io/release/v1.23.0/bin/linux/amd64/kubectl
sudo mv kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl

curl -LO "https://dl.k8s.io/release/v1.23.0/bin/linux/amd64/kubectl-convert"
sudo mv kubectl-convert /usr/local/bin/
chmod +x /usr/local/bin/kubectl-convert

# Create AWS Load Balancer Controller IAM Policy
curl -o lbc_iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.5.4/docs/install/iam_policy.json

export POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"

PN=`aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" --query "Policy.PolicyName"`

if [[ -z "${PN}" ]]; then
  echo "Policy AWSLoadBalancerControllerIAMPolicy is not found, creating ..."
  aws iam create-policy \
      --policy-name ${POLICY_NAME} \
      --policy-document file://lbc_iam_policy.json
else
  echo "Policy ${POLICY_NAME} already exists"
fi

# Prepare VPI ID and subnet IDs
export VPC_ID=$(eksctl get cluster --name ${EKS_CLUSTER_NAME} \
  --region ${AWS_REGION} \
  -o json | jq -r '.[0].ResourcesVpcConfig.VpcId')
   
export SUBNETa=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID \
  Name=tag:kubernetes.io/role/internal-elb,Values=1 \
  Name=availability-zone,Values="${AWS_REGION}"a \
  --query 'Subnets[*].SubnetId' --output text)
  
export SUBNETb=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID \
  Name=tag:kubernetes.io/role/internal-elb,Values=1 \
  Name=availability-zone,Values="${AWS_REGION}"b \
  --query 'Subnets[*].SubnetId' --output text)
  
export SUBNETc=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID \
  Name=tag:kubernetes.io/role/internal-elb,Values=1 \
  Name=availability-zone,Values="${AWS_REGION}"c \
  --query 'Subnets[*].SubnetId' --output text)
    
# Create EFS node group
cat << EOF > node-group.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${EKS_CLUSTER_NAME}
  region: ${AWS_REGION}
  
vpc:
  id: "$VPC_ID"
  subnets:
    private:
      ${AWS_REGION}a:
        id: "$SUBNETa"
      ${AWS_REGION}b:
        id: "$SUBNETb"

managedNodeGroups:
- name: controller
  desiredCapacity: 2
  minSize: 0
  maxSize: 3
  instanceType: m5.large
  privateNetworking: true
  labels:
    app: lbc
    
- name: app
  desiredCapacity: 2
  minSize: 0
  maxSize: 2
  instanceType: t3.medium
  privateNetworking: true
  subnets:
  - ${AWS_REGION}a
  labels:
    app: tomcat
  taints:
  - key: app
    value: tomcat
    effect: NoSchedule
    
nodeGroups:
- name: app2
  desiredCapacity: 2
  minSize: 0
  maxSize: 3
  instanceType: t3.medium
  privateNetworking: true
  subnets:
  - ${AWS_REGION}a
  labels:
    app: tomcat2
  taints:
  - key: app
    value: tomcat2
    effect: NoSchedule
EOF

# Install AWS Load Balancer Controller
eksctl create iamserviceaccount \
    --region us-west-2 \
    --cluster ${EKS_CLUSTER_NAME} \
    --name aws-load-balancer-controller \
    --namespace kube-system \
    --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm -n kube-system upgrade -i aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --set clusterName=${EKS_CLUSTER_NAME} \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set logLevel=debug \
  --set nodeSelector.app=lbc \
  --set tolerations[0].operator=Exists,tolerations[0].effect=NoSchedule,tolerations[0].key=app \
  --wait

cat > ng-values.yaml <<EOF
controller:
  replicaCount: 2
  minAvailable: 1
  service:
    enabled: true
    external:
      enabled: true
    annotations: 
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
      service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    type: LoadBalancer
EOF
# Install nginx ingress controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f ng-values.yaml \
  --version 4.2.4
  
# Deploy sample nginx ingress application
kubectl create deploy httpd --image httpd:latest

kubectl expose deployment/httpd --port 80

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-httpd
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: httpd
            port:
              number: 80
  ingressClassName: nginx
EOF

# Deploy sample applications
mkdir apps

cat << EOF > apps/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: web
EOF

cat << EOF > apps/tomcat.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tomcat
  namespace: web
data:
  index.html: |
    This is a tomcat server.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: tomcat
  name: tomcat
  namespace: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tomcat
  template:
    metadata:
      labels:
        app: tomcat
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - tomcat
              topologyKey: "kubernetes.io/hostname"
      containers:
      - image: tomcat:8.5.82-jdk8
        imagePullPolicy: IfNotPresent
        name: tomcat
        args:
        - sleep 60s; catalina.sh run
        command:
        - /bin/sh
        - -c
        lifecycle:
          preStop:
            exec:
              command: ['/bin/sh', '-c', 'sleep 10']
        resources:
          requests:
            cpu: "300m"
            memory: "512Mi"
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 3
          failureThreshold: 3
          timeoutSeconds: 1
          successThreshold: 1
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 3
          successThreshold: 1
          timeoutSeconds: 1
          terminationGracePeriodSeconds: 60
        volumeMounts:
        - name: index
          mountPath: "/usr/local/tomcat/webapps/ROOT/index.html"
          subPath: index.html
      volumes:
      - name: index
        configMap:
          name: tomcat
      nodeSelector:
        app: tomcat
      tolerations:
      - effect: NoSchedule
        key: app
        operator: Exists
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: tomcat
  name: tomcat
  namespace: web
spec:
  ports:
  - port: 8080
    protocol: TCP
    targetPort: 8080
  selector:
    app: tomcat
  sessionAffinity: None
  type: ClusterIP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: tomcat-pdb
  namespace: web
spec:
  maxUnavailable: "50%"
  selector:
    matchLabels:
      app: tomcat
EOF

cat << EOF > apps/nginx.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx
  namespace: web
data:
  nginx.conf: |
    user  nginx;
    worker_processes  auto;

    error_log  /var/log/nginx/error.log notice;
    pid        /var/run/nginx.pid;


    events {
        worker_connections  1024;
    }


    http {
        include       /etc/nginx/mime.types;
        default_type  application/octet-stream;

        log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$http_x_forwarded_for"';

        access_log  /var/log/nginx/access.log  main;

        sendfile        on;
        #tcp_nopush     on;

        keepalive_timeout  10;
        keepalive_requests 10;

        #gzip  on;

        #include /etc/nginx/conf.d/*.conf;
        
        resolver 10.100.0.10 valid=0;
        
        server {
            listen       80;
            listen  [::]:80;
            server_name  localhost;

            #access_log  /var/log/nginx/host.access.log  main;

            location / {
                proxy_pass http://tomcat:8080;
                proxy_http_version 1.0;
                proxy_set_header Connection "";
            }

            #error_page  404              /404.html;

            # redirect server error pages to the static page /50x.html
            #
            error_page   500 502 503 504  /50x.html;
            location = /50x.html {
                root   /usr/share/nginx/html;
            }
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: nginx
  name: nginx
  namespace: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - nginx
              topologyKey: "kubernetes.io/hostname"
      containers:
      - image: nginx:1.23.1
        imagePullPolicy: IfNotPresent
        name: nginx
        lifecycle:
          preStop:
            exec:
              command: ['/bin/sh', '-c', 'sleep 10']
        resources: {}
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 3
          failureThreshold: 3
          timeoutSeconds: 1
          successThreshold: 1
        volumeMounts:
        - name: nginxconf
          mountPath: "/etc/nginx/nginx.conf"
          subPath: nginx.conf
      volumes:
      - name: nginxconf
        configMap:
          name: nginx
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: nginx-nlb
  name: nginx-nlb
  namespace: web
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx
  sessionAffinity: None
  type: LoadBalancer
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ng-pdb
  namespace: web
spec:
  maxUnavailable: "50%"
  selector:
    matchLabels:
      app: nginx
---
EOF

kubectl apply -f apps/namespaces.yaml
kubectl apply -f apps/tomcat.yaml
kubectl -n web wait --for=condition=Ready pod -l app=tomcat --timeout=120s
kubectl apply -f apps/nginx.yaml

# Deploy k6 to test the nginx application
export NX_ENDPOINT=$(kubectl get svc nginx-nlb -n web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

for i in {1..6}
do
  if [[ -z "${NX_ENDPOINT}" ]]; then
    echo "Waiting for external hostname to be ready ..."
    sleep 5
    export NX_ENDPOINT=$(kubectl get svc nginx-nlb -n web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  else
    break
  fi
done

cat << EOF > apps/k6.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6script
  namespace: default
data:
  script.js: |
    import http from 'k6/http';
    import { sleep } from 'k6';
    export default function () {
      const params = {
        timeout: "2s",
      };
      http.get('http://nginx-nlb.web');
      sleep(1);
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: k6
  namespace: default
spec:
  containers:
  - image: grafana/k6:latest
    name: k6
    args:
    - run
    - --http-debug=headers
    - --duration=120m
    - /home/k6/script.js
    volumeMounts:
    - name: k6script
      mountPath: "/home/k6/script.js"
      subPath: script.js
  volumes:
  - name: k6script
    configMap:
      name: k6script
  restartPolicy: Never
EOF

# Install HPA
cat <<EOF > apps/hpa.yaml
apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: fake-hpa
  namespace: default
  labels:
    eventing.knative.dev/release: "v1.2.0"
    app.kubernetes.io/component: fake-apps
    app.kubernetes.io/version: "1.2.0"
    app.kubernetes.io/name: fake-apps
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: fake-deployment
  minReplicas: 1
  maxReplicas: 5
EOF

kubectl apply -f apps/hpa.yaml