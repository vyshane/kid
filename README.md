# kid - [Kubernetes](http://kubernetes.io) in [Docker](https://www.docker.com)

Launch Kubernetes in Docker in one `kid up` command.

```
 ❱ kid 
kid is a utility for launching Kubernetes in Docker
Usage: kid [command]

Available commands:
  up       Starts Kubernetes in the Docker host currently configured with your local docker command
  down     Tear down a previously started Kubernetes cluster
  restart  Restart Kubernetes
```

On Linux kid will launch Kubernetes using the local Docker Engine.

On OS X Kubernetes will be started in the boot2docker VM via Docker Machine. kid sets up port forwarding so that you can use kubectl locally without having to ssh into boot2docker.

kid also sets up:

 * The [DNS addon](https://github.com/kubernetes/kubernetes/tree/master/cluster/addons/dns)
 * The [Kubernetes Dashboard](https://github.com/kubernetes/dashboard)

## [Known Issue with ConfigMaps and Docker Machine](https://github.com/kubernetes/kubernetes/issues/23392)

In order to get ConfigMaps to work when running Kubernetes via Docker Machine, first start your Docker Machine VM, then run:

```
docker-machine ssh $(docker-machine active) sudo mount --make-shared /
```
