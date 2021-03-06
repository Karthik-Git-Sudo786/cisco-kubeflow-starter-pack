#!/bin/bash -e

# Copyright 2018 The Kubeflow Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x

KUBERNETES_NAMESPACE="${KUBERNETES_NAMESPACE:-kubeflow}"
SERVER_NAME="${SERVER_NAME:-model-server}"

while (($#)); do
   case $1 in
     "--timestamp")
       shift
       TIMESTAMP="$1"
       shift
       ;;
     *)
       echo "Unknown argument: '$1'"
       exit 1
       ;;
   esac
done

if [ -z "${TIMESTAMP}" ]; then
  echo "Timestamp needs to be added"
  exit 1
fi

echo "Deploying the model"

CLUSTER_NAME=ucs
# Connect kubectl to the local cluster
kubectl config set-cluster "${CLUSTER_NAME}" --server=https://kubernetes.default --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
kubectl config set-credentials pipeline --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
kubectl config set-context kubeflow --cluster "${CLUSTER_NAME}" --user pipeline
kubectl config use-context kubeflow

#Making folder to store yaml files for kustomization
mkdir network_serve
cd network_serve/
touch kustomization.yaml network_serve.yaml network_service.yaml

#Writing code into yaml files
cat >> kustomization.yaml << EOF
resources:
- network_serve.yaml
- network_service.yaml

namePrefix: serve-
EOF
sed -i "s/serve-/serve-$TIMESTAMP-/g" kustomization.yaml

cat >> network_serve.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: network
    timestamp: timestamp-value
  name: network
  namespace: kubeflow
spec:
  selector:
    matchLabels:
      app: network
      timestamp: timestamp-value
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "true"
      labels:
        app: network
        timestamp: timestamp-value
        version: v1
    spec:
      containers:
      - args:
        - --port=9000
        - --rest_api_port=8500
        - --model_base_path=/mnt/Model_Network/Model_Network
        env:
        - name: MODEL_NAME
          value: "Model_Network"
        image: tensorflow/serving
        name: tensorflow-serving
        resources:
          limits:
            memory: 750Mi
            cpu: 0.5
          requests:
            memory: 512Mi
            cpu: 0.25
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - mountPath: "/mnt/Model_Network/"
          name: "nfsvolume"
      volumes:
       - name: "nfsvolume"
         persistentVolumeClaim:
           claimName: "nfs"
EOF
sed -i "s/timestamp-value/ts-$TIMESTAMP/g"  network_serve.yaml
cat >> network_service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: network
    timestamp: timestamp-value
  name: network-service
  namespace: kubeflow
spec:
  ports:
  - name: grpc-tf-serving
    port: 9000
    targetPort: 9000
  - name: http-tf-serving
    port: 8500
    targetPort: 8500
  selector:
    app: network
    timestamp: timestamp-value
  type: ClusterIP
EOF
sed -i "s/timestamp-value/ts-$TIMESTAMP/g"  network_service.yaml

echo "Installing kustomize"
wget https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv3.5.4/kustomize_v3.5.4_linux_amd64.tar.gz
tar -xvf kustomize_v3.5.4_linux_amd64.tar.gz
export PATH=$PATH:$PWD

#Building a service and a deployment using kustomize
kustomize build . | kubectl apply -f -

kubectl get deployment serve-$TIMESTAMP-network -n kubeflow

kubectl get svc serve-$TIMESTAMP-network-service -n kubeflow

echo "Writing Prediction result files to Visualisation server"

vis_podname=$(kubectl -n kubeflow get pods --field-selector=status.phase=Running | grep ml-pipeline-visualizationserver | awk '{print $1}')

kubectl cp /mnt/network_source.xlsx $vis_podname:/src -n kubeflow
