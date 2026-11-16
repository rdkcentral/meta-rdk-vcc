This README file contains information on the contents of the meta-rdk-vcc layer.

Please see the corresponding sections below for details.

Dependencies
============

VCC class uses a yaml file format for storing the build manifest. 
You need the following python packages on your build env.
* pip install pyyaml
An example yaml file is provided in the yaml_samples folder.

Patches
=======

Layer Maintainers: 
	Beri Levi
	Retheesh Sasidharan

Table of Contents
=================

  I. Adding the meta-rdk-vcc layer to your build


I. Adding the meta-rdk-vcc layer to your build
=================================================

Run 'bitbake-layers add-layer ../meta-rdk-vcc'

A packages yaml file per product is required, and vcc class will look for ${MACHINE}.yaml file under each meta-layer directory defined in ${BBLAYERS} variable. 
For example ./meta-rdk-xyz/skysr213-meta-rdk-xyz.yaml

VCC class has to be available globally, by appending to the USER_CLASSES variable. 
This is done automatically from the meta-rdk-vcc/conf/layer.conf
USER_CLASSES_append = " vcc "

#Yaml config store
YAML_CONFIG = ""

#Set the following environment variables in a ${MACHINE}.conf file or layer.conf
PACKAGE_FEED_URIS = "https://link.to/opkg/repo
PACKAGE_FEED_BASE_PATHS = "${MACHINE}"
PACKAGE_FEED_ARCHS = "all"
