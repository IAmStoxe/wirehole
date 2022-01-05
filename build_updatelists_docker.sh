#!/bin/bash

docker build -t jimaldon/pihole-updatelists:latest --file Dockerfile.pihole-updatelists .
docker push jimaldon/pihole-updatelists:latest
