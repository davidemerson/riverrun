#!/bin/bash

mkdir /usr/bin/riverrun

cp -R converter/ /usr/bin/riverrun/converter
cp -R streamer/ /usr/bin/riverrun/streamer

mkdir -p /var/music/uploads
mkdir -p /var/music/queue