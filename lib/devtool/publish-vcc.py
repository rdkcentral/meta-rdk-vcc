# If not stated otherwise in this file or this component's LICENSE file the
# following copyright and licenses apply:
#
# Copyright 2025 Sky UK
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

"""
Devtool plugin for package publishing operations.

Provides the following commands:

devtool publish:
* Parse a recipe and determine packages to publish.
* Retrieve repository credentials (if needed).
* Upload packages to a package repository (e.g., JFrog Artifactory).

devtool publish_manifest:
* Upload packages for all the recipes in the input yaml manifest file to a package repository (e.g., JFrog Artifactory).

Command-line Switches:

publish:
* **recipename:**  Required. The name of the recipe to publish (without version, path, or extension).
* **--subdirectory, -s:**  Optional. Subdirectory within the package repository for the upload.
* **--url, -u:** Optional. Overrides the default package repository URL from PACKAGE_FEED_URIS.

publish_manifest:
* **manifest:**  Required. The name of the yaml manifest file .
* **--url, -u:** Optional. Overrides the default package repository URL from PACKAGE_FEED_URIS.

Usage Example:
devtool publish 'recipe-name'
devtool publish_manifest 'machine.yaml'
"""

import os
import subprocess
import logging
from bb.process import ExecutionError
from devtool import exec_build_env_command, setup_tinfoil, check_workspace_recipe, DevtoolError
from devtool import parse_recipe

logger = logging.getLogger('devtool')

#Function to execute commands in device shell
def cmdline(command):
    from subprocess import PIPE, Popen
    process = Popen(args=command, stdout=PIPE, stderr=PIPE, shell=True)
    # If the curl command fails locally, the error message must be collected
    # from the stderr of Popen.
    msg2 = process.stderr.read()
    #bb.warn("Executing cmd:  %s "%command)
    # The variable msg will have the response from the remote server, it can
    # either be a success or failure message with details.
    msg = process.communicate()[0]

    # In case of a local curl command failure, process.returncode will be non-zero
    if process.returncode:
        # Collect the local failure message
        msg = str(msg2).split("curl:")[1].strip()

    return  process.returncode, msg

def get_password(hostname):
    import netrc

    try:
        # Load the .netrc file
        netrc_file = netrc.netrc()
        # Retrieve the login information for the given host
        login_info = netrc_file.authenticators(hostname)
        # Check if login information is available
        if login_info is not None:
            username, _, password = login_info
            return password
        else:
            bb.warn("Error: Could not find host %s.."%hostname)
            return None
    except FileNotFoundError:
        bb.warn("Error: .netrc file not found.")
        return None

#Function to copy files to Jfrog
def push_package(ipk_path, jfrog_path, password):
    import json

    curl_url = 'curl -H ' + '"' + password + '"' + ' -XPUT ' + '"' + jfrog_path+ '"'  + ' -T ' + ipk_path
    err, msg = cmdline(curl_url)
    ret_message = None
    ret_ipk_path = None
    if err == 0:
        # err value could be zero even if any issues occured while execting the requested operation
        # in the remote server. Need to examin the json message from the remote setver to get the 
        # correct status of operation.
        status_dict = json.loads(msg)
        if "errors" in status_dict:
            for item in status_dict["errors"]:
                ret_message = item["message"]
            ret_ipk_path = ipk_path
    else:
        # If the curl command fails locally, the err value would be non zero.
        ret_message = "Curl command failed: %s"%msg
        ret_ipk_path = ipk_path
    return ret_ipk_path, ret_message

# File upload function
def do_upload_packages(package_list, jfrog_path, password, tinfoil, do_multiprocess = False):

    import multiprocessing
    from itertools import repeat

    def split_into_batches(lst, batch_size=10):
        for i in range(0, len(lst), batch_size):
            yield lst[i:i + batch_size]

    # Initialize multiprocessing
    cpu_count = multiprocessing.cpu_count()
    pool = multiprocessing.Pool(cpu_count)

    bb.warn("Starting file upload ..")
    pkg_total_count = len(package_list)
    max_trials = 5
    for attempt in range(max_trials):
        bb.warn("\nUpload attempt: %d/%d\n"%(attempt+1, max_trials))
        # upload_results_list would be the list of tuples in witch
        # each tuple has the structure (ipk_path, error_message)
        # list(p.starmap(push_package, zip(final_file_list, jfrog_path_list, password_list)))
        upload_results_list = []
        progress = 0
        if do_multiprocess:
            for ipk_batch in split_into_batches(package_list, batch_size=(cpu_count*2)):
                # Create tuple list of arguments to pass to the multiprocessed
                # push_package function where each tuple has the structure
                # (ipk_path, jfrog_path, password) to be passed to each invokation
                upload_args_list = zip(ipk_batch, repeat(jfrog_path), repeat(password))
                upload_results_list.extend(list(pool.starmap(push_package, upload_args_list)))
                progress += len(ipk_batch)
                bb.warn("Upload progress: %d/%d : " % (progress, len(package_list)) +
                        "%s to %s" % (ipk_path, jfrog_path))
        else:
            # Upload all packages sequentially
            for ipk_path in package_list:
                upload_results_list.append(push_package(ipk_path, jfrog_path, password))
                progress += 1
                bb.warn("Upload progress: %d/%d : " % (progress, len(package_list)) +
                        "%s to %s" % (ipk_path, jfrog_path))

        # In the returned tuple list, the tuples represending successful uploades
        # would be (none, none). All other tuples would have ipk name and error
        # messages in them. Filter those tuples out and recreate the upload file list 
        bb.warn("Upload attempt %d completed..Checking the upload results...\n"%(attempt +1))
        package_list = [item[0] for item in upload_results_list if item[1] is not None]
        # Before doing the next attemp, log the error messages with failed ipks.
        if not package_list:
            # All files uploaded successfully, no more attempts
            break
        if attempt < (max_trials -1):
            bb.warn("Found upload failures, trying again...")

    if package_list:
        bb.error("Could not upload the following files..")
        for item in upload_results_list:
            if item[0] is not None:
                bb.warn("  %s : %s"%(item[0], item[1]))

    # return count of success and failure
    return pkg_total_count-len(package_list), len(package_list)

def get_recipe_ipks(d):
    """Get the list of IPK files for the current recipe"""
    import os

    arch = d.getVar('PACKAGE_ARCH')
    pkg_ipk_dir = d.getVar('PKGWRITEDIRIPK')

    if not arch or not pkg_ipk_dir:
        bb.warn("PACKAGE_ARCH or PKGWRITEDIRIPK is not set")
        return []
    
    deploy_ipks_path = os.path.join(pkg_ipk_dir, arch)
    
    if not os.path.exists(deploy_ipks_path):
        bb.warn(f"IPK deploy path does not exist: {deploy_ipks_path}")
        return []

    try:
        with os.scandir(deploy_ipks_path) as entries:
            ipk_files = sorted(f.path for f in entries if f.is_file() and f.name.endswith('.ipk'))
    except Exception as e:
        bb.warn(f"Error listing {deploy_ipks_path}: {e}")
        return []
    
    #bb.warn(f"Found IPK files: {ipk_files}")
    return ipk_files

# Function to push packages sequentially
def push_recipe_packages(pn, url, subdir, d):
    """Push the IPK files of a recipe to the package repository"""
    ipk_list = get_recipe_ipks(d)
    if not ipk_list:
        bb.error("No IPK files found for recipe %s. Please build the recipe before publishing." % pn)
        return 
    
    host_name = d.getVar("RDK_ARTIFACTS_URL", True).split("/")[0]
    password = get_password(host_name)
    if password == None:
        bb.error("Could not read password for %s.."%host_name)
        return
    password = "X-JFrog-Art-Api:%s" % password
    base_url = d.getVar("PACKAGE_FEED_URIS", True)

    if url != None:
        base_url = url
    if subdir != None:
        jfrog_path = base_url + '/' + subdir + '/'
    else:
        bb.error("Subdir argument -s is required for publishing recipes...")
        return

    # Do parallel file upload
    upload_count, fail_count = do_upload_packages(ipk_list, jfrog_path, password, d.tinfoil)
    # Display upload status info
    display_upload_status(len(ipk_list), upload_count, fail_count)

def publish(args, config, basepath, workspace):
    """Entry point for the devtool 'publish' subcommand"""
    import bb

    args.tinfoil = getattr(args, 'tinfoil', False)

    if args.tinfoil:
        tinfoil = args.tinfoil
    else:
        tinfoil = setup_tinfoil(basepath=basepath, tracking=True)

    try:
        rd = parse_recipe(config, tinfoil, args.recipename, True)
        if not rd:
            bb.error("Could not find a valid recipe for %s.."%args.recipename)
            if not args.tinfoil:
                tinfoil.shutdown()
            return 1
        rd.setVar("command", "publish")
        pn = rd.getVar('PN')
        if pn != args.recipename:
            logger.info('Mapping %s to %s' % (args.recipename, pn))

        push_recipe_packages(pn, args.url, args.subdirectory, rd)
    finally:
        if not args.tinfoil:
            tinfoil.shutdown()
    return 0

# Function to get paths to all sub folders in a route directory
def list_subdirectories(root_directory):
    subdirectories = []
    for root, dirs, files in os.walk(root_directory):
        for directory in dirs:
            subdirectories.append(os.path.join(root, directory))
    return subdirectories

# Publishes all the ipks listed in a manidest file.
def publish_manifest(args, config, basepath, workspace):
    """Entry point for the devtool 'publish_manifest' subcommand"""
    import yaml
    from yaml.loader import SafeLoader
    import bb

    args.tinfoil = getattr(args, 'tinfoil', False)
    if args.tinfoil:
        tinfoil = args.tinfoil
    else:
        tinfoil = setup_tinfoil(basepath=basepath, tracking=True)

    package_list_yaml = args.manifest
    if not os.path.isabs(package_list_yaml):
        # If the input file name does not have absolute path, try to read it from DEPLOY_DIR_IMAGE or DEPLOY_DIR_IMAGE/yaml-manifests
        package_list_yaml = os.path.join(tinfoil.config_data.getVar("DEPLOY_DIR_IMAGE"), args.manifest)
        if not os.path.exists(package_list_yaml):
            package_list_yaml = os.path.join(tinfoil.config_data.getVar("DEPLOY_DIR_IMAGE"), "yaml-manifests", args.manifest)
            if not os.path.exists(package_list_yaml):
                bb.error("Could not find the input manifest file.." +
                         "\n  Please provide the full path or make sure the file is present in either of the following directories." +
                         "\n    1. %s\n    2. %s"%(tinfoil.config_data.getVar("DEPLOY_DIR_IMAGE"),
                                                   os.path.join(tinfoil.config_data.getVar("DEPLOY_DIR_IMAGE"), "yaml-manifests")))
                if not args.tinfoil:
                    tinfoil.shutdown()
                return

    #Open yaml file to read recipe name
    try:
        with open(package_list_yaml, 'r') as outfile:
            data = yaml.safe_load(outfile)
    except Exception as e:
        bb.error(f"Could not load the input manifest file {package_list_yaml}. Please ensure it is a valid YAML file. Error: {e}")
        if not args.tinfoil:
            tinfoil.shutdown()
        return
    try:
        host_name = tinfoil.config_data.getVar("RDK_ARTIFACTS_URL").split("/")[0]
        password = get_password(host_name)
        if password == None:
            if not args.tinfoil:
                tinfoil.shutdown()
            return 0

        password = "X-JFrog-Art-Api:%s" % password
        jfrog_path = data['Globals']['Product']
        if data['Globals']['Layer'] != None:
            jfrog_path += "/" + data['Globals']['Layer']
        if data['Globals']['Release'] != None:
            jfrog_path += "/" + data['Globals']['Release']

        for recipe, value in data['Recipes'].items():
            bb.warn("Processing recipe: %s"%recipe)
            rd = parse_recipe(config, tinfoil, recipe, True)
            push_recipe_packages(recipe, None, jfrog_path, rd)

    finally:
        if not args.tinfoil:
            tinfoil.shutdown()
    return 0

def display_upload_status(total, success, failure):
    bb.warn("Upload status:")
    bb.warn("  Total input package names : %d"% total)
    bb.warn("  Uploaded Packages         : %d"% success)
    bb.warn("  Upload failed             : %d"% failure)

def register_commands(subparsers, context):
    """Register devtool subcommands from the package plugin"""
    parser_publish = subparsers.add_parser('publish', help='Upload ipks of a recipe to package repository',
                                       description='Upload ipks of a recipe to package repository',
                                       group='starting', order=10)
    parser_publish.add_argument('recipename', help='Name of recipe whose ipks to upload (just name - no version, path or extension)')
    parser_publish.add_argument('--subdirectory','-s', default=None, help='Subdirectory, will be used in the IPK upload path')
    parser_publish.add_argument('--url', '-u', default=None, help='Replaces the URL for the IPK repository, by default the value from PACKAGE_FEED_URIS is used.')
    parser_publish.set_defaults(func=publish)
    
    """Register devtool subcommands from the package plugin"""
    parser_publish_manifest = subparsers.add_parser('publish_manifest', help='Upload ipks listed by the yaml manifest file',
                                       description='Upload ipks of all the recipes included in a manifest file.',
                                       group='starting', order=10)
    parser_publish_manifest.add_argument('manifest', help='Name or full path of the manifest yaml file with the ipks to upload.' +
                                         'If the parater value does not have the absolute path(ie. starts with /), the command would try to access the ' +
                                         'file path from DEPLOY_DIR_IMAGE or DEPLOY_DIR_IMAGE/yaml_manifests/ .')
    parser_publish_manifest.add_argument('--url', '-u', default=None, help='Replaces the URL for the IPK repository, by default the value from PACKAGE_FEED_URIS is used.')
    parser_publish_manifest.set_defaults(func=publish_manifest)
