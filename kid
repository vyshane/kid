#!/bin/bash
#
# kid is a helper script for launching Kubernetes in Docker

KUBERNETES_VERSION=1.2.4
KUBERNETES_API_PORT=8080
KUBERNETES_DASHBOARD_NODEPORT=31999
DNS_DOMAIN=cluster.local
DNS_SERVER_IP=10.0.0.10

# set -e

function print_usage {
    cat << EOF
kid is a utility for launching Kubernetes in Docker

Usage: kid [command]

Available commands:
  up       Starts Kubernetes in the Docker host currently configured with your local docker command
  down     Tear down a previously started Kubernetes cluster
  restart  Restart Kubernetes
EOF
}

function check_prerequisites {
    function require_command_exists() {
        command -v "$1" >/dev/null 2>&1 || \
	    { echo "$1 is required but is not installed. Aborting." >&2; exit 1; }
    }
    require_command_exists kubectl
    require_command_exists docker
    docker info > /dev/null
    if [ $? != 0 ]; then
        echo A running Docker engine is required. Is your Docker host up?
        exit 1
    fi

    # Fixed shared mount for docker machine.
    if [ -n $(active_docker_machine) ]; then
      fix_shared_mount "/"
    fi

    docker info | egrep -q 'Kernel Version: .*-moby'
    if [ $? -eq 0 ]; then
      echo "Docker for Mac detected"

      if [ "$(pinata get native/port-forwarding)" == "true" ]; then
        pinata set native/port-forwarding false >/dev/null
        if [ $? -ne 0 ]; then
          echo "error setting pinata native/port-forwarding to false."
          exit 1
        fi
        sleep 5
        docker info >/dev/null 2>&1
        while [ $? -ne 0 ]; do sleep 1 ; docker info >/dev/null 2>&1; done # wait for docker to come back
      fi

      # Mount /var as shared to fix configmaps.
      fix_shared_mount "/var"
    fi
}

function fix_shared_mount {
  path=$1
  docker run -it --rm --entrypoint=sh --privileged --net=host -e sysimage=/host -v /:/host -v /dev:/dev -v /run:/run gcr.io/google_containers/hyperkube-amd64:v${KUBERNETES_VERSION} -c 'nsenter --mount=$sysimage/proc/1/ns/mnt -- mount --make-shared '$path''
}

function active_docker_machine {
    if [ $(command -v docker-machine) ]; then
        docker-machine active
    fi
}

function forward_port_if_necessary {
    local port=$1
    local machine=$(active_docker_machine)

    if [ -n "$machine" ]; then
        if ! pgrep -f "ssh.*$port:localhost" > /dev/null; then
            docker-machine ssh "$machine" -f -N -L "$port:localhost:$port"
        else
            echo Did not set up port forwarding to the Docker machine: An ssh tunnel on port $port already exists. The kubernetes cluster may not be reachable from local kubectl.
        fi
    fi

    docker info | egrep -q 'Kernel Version: .*-moby'
    if [ $? -eq 0 ]; then
      AVAHI_HOST=docker-mac
      docker kill avahi-${AVAHI_HOST} >/dev/null 2>&1 || true ; docker rm avahi-${AVAHI_HOST} >/dev/null 2>&1 || true
      docker run -d --name avahi-${AVAHI_HOST} --net host --restart always -e AVAHI_HOST=${AVAHI_HOST} danisla/avahi:latest >/dev/null

      SCRIPTPATH=$( cd $(dirname $0) ; pwd -P )
      [[ -h $0 ]] && SCRIPTPATH=$(dirname `readlink $0`)
      SSH_KEY="${SCRIPTPATH}/kid_rsa.key"
      [[ ! -f "${SSH_KEY}" ]] && ssh-keygen -t rsa -f "${SSH_KEY}" -N '' >/dev/null

      docker run --name kid_ssh -d --net host -v "${SSH_KEY}.pub":/etc/ssh/keys/kid_rsa.key.pub:ro danisla/ssh-server:latest > /dev/null
      nohup ssh -f -N -i "${SSH_KEY}" -L 8080:localhost:8080 nobody@docker-mac.local >/dev/null 2>&1 &
    fi
}

function forward_canary_port_if_necessary {
  port=$1
  docker info | egrep -q 'Kernel Version: .*-moby'
  if [ $? -eq 0 ]; then
    # Keep port forward alive.
    nohup bash -c 'while true; do kubectl --namespace kube-system port-forward $(kubectl --namespace kube-system get pod --selector=app=kubernetes-dashboard-canary -o jsonpath={.items..metadata.name}) '$port':9090; sleep 2; done' >/dev/null 2>&1 &
    nc -z localhost 31999
    while [ $? -ne 0 ]; do sleep 1 ; nc -z localhost 31999; done
  fi
}

function remove_port_forward_if_forwarded {
    local port=$1
    pkill -f "ssh.*docker.*$port:localhost:$port"

    # port-forward the canary dashboard.
    docker info | egrep -q 'Kernel Version: .*-moby'
    if [ $? -eq 0 ]; then
      docker kill kid_ssh >/dev/null 2>&1 || true ; docker rm kid_ssh >/dev/null 2>&1 || true

      pkill -f "kubectl.*port-forward.*dashboard-canary.*"

      # Reset the port forwarding setting.
      if [ "$(pinata get native/port-forwarding)" == "false" ]; then
        echo "reseting Docker for Mac native/port-forwarding = true"
        pinata set native/port-forwarding true >/dev/null
        if [ $? -ne 0 ]; then
          echo "error setting pinata native/port-forwarding to true."
          exit 1
        fi
        sleep 5
        docker info >/dev/null 2>&1
        while [ $? -ne 0 ]; do sleep 1 ; docker info >/dev/null 2>&1; done # wait for docker to come back
      fi
    fi
}

function wait_for_kubernetes {
    until $(kubectl cluster-info &> /dev/null); do
        sleep 1
    done
}

function create_kube_system_namespace {
    kubectl create -f - << EOF > /dev/null
kind: Namespace
apiVersion: v1
metadata:
  name: kube-system
  labels:
    name: kube-system
EOF
}

function activate_kubernetes_dashboard {
    local dashboard_service_nodeport=$1
    kubectl create -f - << EOF > /dev/null
# Source: https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/kubernetes-dashboard-canary.yaml
kind: List
apiVersion: v1
items:
- kind: ReplicationController
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
      version: canary
    name: kubernetes-dashboard-canary
    namespace: kube-system
  spec:
    replicas: 1
    selector:
      app: kubernetes-dashboard-canary
      version: canary
    template:
      metadata:
        labels:
          app: kubernetes-dashboard-canary
          version: canary
      spec:
        containers:
        - name: kubernetes-dashboard-canary
          image: gcr.io/google_containers/kubernetes-dashboard-amd64:canary
          imagePullPolicy: Always
          ports:
          - containerPort: 9090
            protocol: TCP
          args:
            # Uncomment the following line to manually specify Kubernetes API server Host
            # If not specified, Dashboard will attempt to auto discover the API server and connect
            # to it. Uncomment only if the default does not work.
            # - --apiserver-host=http://my-address:port
          livenessProbe:
            httpGet:
              path: /
              port: 9090
            initialDelaySeconds: 30
            timeoutSeconds: 30
- kind: Service
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
    name: dashboard-canary
    namespace: kube-system
  spec:
    type: NodePort
    ports:
    - port: 80
      targetPort: 9090
      nodePort: $dashboard_service_nodeport  # Addition. Not present in upstream definition.
    selector:
      app: kubernetes-dashboard-canary
    type: NodePort
EOF
}

function start_dns {
    local dns_domain=$1
    local dns_server_ip=$2

    kubectl create -f - << EOF > /dev/null
apiVersion: v1
kind: ReplicationController
metadata:
  name: kube-dns-v10
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    version: v10
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 1
  selector:
    k8s-app: kube-dns
    version: v10
  template:
    metadata:
      labels:
        k8s-app: kube-dns
        version: v10
        kubernetes.io/cluster-service: "true"
    spec:
      containers:
      - name: etcd
        image: gcr.io/google_containers/etcd-amd64:2.2.1
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        command:
        - /usr/local/bin/etcd
        - -data-dir
        - /var/etcd/data
        - -listen-client-urls
        - http://127.0.0.1:2379,http://127.0.0.1:4001
        - -advertise-client-urls
        - http://127.0.0.1:2379,http://127.0.0.1:4001
        - -initial-cluster-token
        - skydns-etcd
        volumeMounts:
        - name: etcd-storage
          mountPath: /var/etcd/data
      - name: kube2sky
        image: gcr.io/google_containers/kube2sky:1.12
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        args:
        # command = "/kube2sky"
        - --domain=$dns_domain
      - name: skydns
        image: gcr.io/google_containers/skydns:2015-10-13-8c72f8c
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        args:
        # command = "/skydns"
        - -machines=http://127.0.0.1:4001
        - -addr=0.0.0.0:53
        - -ns-rotate=false
        - -domain=${dns_domain}.
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 30
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 1
          timeoutSeconds: 5
      - name: healthz
        image: gcr.io/google_containers/exechealthz:1.0
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 10m
            memory: 20Mi
          requests:
            cpu: 10m
            memory: 20Mi
        args:
        - -cmd=nslookup kubernetes.default.svc.${dns_domain} 127.0.0.1 >/dev/null
        - -port=8080
        ports:
        - containerPort: 8080
          protocol: TCP
      volumes:
      - name: etcd-storage
        emptyDir: {}
      dnsPolicy: Default  # Don't use cluster DNS.
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: $dns_server_ip
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
EOF
}

function start_kubernetes {
    local kubernetes_version=$1
    local kubernetes_api_port=$2
    local dashboard_service_nodeport=$3
    local dns_domain=$4
    local dns_server_ip=$5
    check_prerequisites

    if kubectl cluster-info 2> /dev/null; then
        echo kubectl is already configured to use an existing cluster
        exit 1
    fi

    docker run \
        --name=kubelet \
        --volume=/:/rootfs:ro \
        --volume=/sys:/sys:ro \
        --volume=/var/lib/docker/:/var/lib/docker:rw \
        --volume=/var/lib/kubelet/:/var/lib/kubelet:rw,shared \
        --volume=/var/run:/var/run:rw \
        --net=host \
        --pid=host \
        --privileged=true \
        -d \
        gcr.io/google_containers/hyperkube-amd64:v${kubernetes_version} \
        /hyperkube kubelet \
            --containerized \
            --hostname-override="127.0.0.1" \
            --address="0.0.0.0" \
            --api-servers=http://localhost:${kubernetes_api_port} \
            --config=/etc/kubernetes/manifests \
            --cluster-dns=$DNS_SERVER_IP \
            --cluster-domain=$DNS_DOMAIN \
            --allow-privileged=true --v=2 \
	    > /dev/null

    # TODO: Set and use a `kid` Kubernetes context instead of forwarding the port?
    forward_port_if_necessary $kubernetes_api_port

    echo Waiting for Kubernetes cluster to become available...
    wait_for_kubernetes
    create_kube_system_namespace
    start_dns $dns_domain $dns_server_ip
    activate_kubernetes_dashboard $dashboard_service_nodeport

    forward_canary_port_if_necessary $dashboard_service_nodeport

    echo Kubernetes cluster is up. The Kubernetes dashboard can be accessed via HTTP at port $dashboard_service_nodeport of your Docker host.
}

function delete_kubernetes_resources {
    kubectl delete replicationcontrollers,services,pods,secrets --all > /dev/null 2>&1 || :
    kubectl delete replicationcontrollers,services,pods,secrets --all --namespace=kube-system > /dev/null 2>&1 || :
    kubectl delete namespace kube-system > /dev/null 2>&1 || :
}

function delete_docker_containers {
    # Remove the kubelet first so that it doesn't restart pods that we're going to remove next
    docker stop kubelet > /dev/null 2>&1
    docker rm -fv kubelet > /dev/null 2>&1

    k8s_containers=$(docker ps -aqf "name=k8s_")
    if [ ! -z "$k8s_containers" ]; then
        docker stop $k8s_containers > /dev/null 2>&1
        docker wait $k8s_containers > /dev/null 2>&1
        docker rm -fv $k8s_containers > /dev/null 2>&1
    fi
}

function stop_kubernetes {
    local kubernetes_api_port=$1
    delete_kubernetes_resources
    delete_docker_containers
    remove_port_forward_if_forwarded $kubernetes_api_port
}

if [ "$1" == "up" ]; then
    start_kubernetes $KUBERNETES_VERSION \
        $KUBERNETES_API_PORT \
        $KUBERNETES_DASHBOARD_NODEPORT \
        $DNS_DOMAIN $DNS_SERVER_IP
elif [ "$1" == "down" ]; then
    # TODO: Ensure current Kubernetes context is set to local Docker (or Docker Machine VM) before downing
    stop_kubernetes $KUBERNETES_API_PORT
elif [ "$1" == "restart" ]; then
    # TODO: Check if not currently running before downing. Show a message if not running.
    kid down && kid up
else
    print_usage
fi
