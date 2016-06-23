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

## Linux

On Linux kid will launch Kubernetes using the local Docker Engine.

## macOS

On macOS kid will start Kubernetes in the boot2docker VM if there is an active Docker Machine. kid then sets up port forwarding so that you can use kubectl locally without having to ssh into boot2docker.

If kid detects a local installation of [Docker for macOS](https://www.docker.com/products/docker#/mac), it uses that instead.

## Addons

kid also sets up:

 * The [DNS addon](https://github.com/kubernetes/kubernetes/tree/master/cluster/addons/dns)
 * The [Kubernetes Dashboard](https://github.com/kubernetes/dashboard)

