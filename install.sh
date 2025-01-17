#!/bin/bash

mkdir /usr/bin/riverrun

cp -R converter/ /usr/bin/riverrun/converter
cp -R streamer/ /usr/bin/riverrun/streamer

mkdir /var/music/uploads
mkdir /var/music/queue