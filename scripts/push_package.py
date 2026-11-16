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


import os
import yaml
import shutil
import pathlib
import multiprocessing
import sys


from yaml.loader import SafeLoader
from subprocess import PIPE, Popen
from urllib.parse import urlparse

def get_hostname_from_url(url):
  """
  Extracts the hostname from a full URL.

  Args:
    url: The full URL string.

  Returns:
    The hostname as a string, or None if the URL is invalid or
    doesn't have a hostname.
  """
  parsed_url = urlparse(url)
  return parsed_url.hostname

#Function to execute commands in device shell
def cmdline(command):
    process = Popen(args=command, stdout=PIPE, shell=True)
    return process.communicate()[0]

def get_package_feed_uris():
    """
    Get PACKAGE_FEED_URIS from Yocto configuration using Tinfoil
    """
    try:
        # Ensure we're in a proper Yocto environment
        import bb.tinfoil
        
        # Initialize Tinfoil
        tinfoil = bb.tinfoil.Tinfoil()
        
        # Prepare with config only to minimize overhead
        tinfoil.prepare(config_only=True)
        
        # Get the variable value
        package_feed_uris = tinfoil.config_data.getVar('PACKAGE_FEED_URIS')
        
        # Print and return the value
        print(f"PACKAGE_FEED_URIS: {package_feed_uris}")
        
        # Cleanup
        tinfoil.shutdown()
        
        return package_feed_uris
        
    except ImportError as e:
        print(f"Import error - Tinfoil not available: {e}")
        return None
    except Exception as e:
        print(f"Error getting PACKAGE_FEED_URIS: {e}")
        return None

def get_password(url):
    import netrc

    try:
        hostname = get_hostname_from_url(url)
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
def push_package(ipk, jfrog_path, password):
    curl_url = 'curl -H ' + '"' + password + '"' + ' -XPUT ' + '"' + jfrog_path+ '"'  + ' -T ' + ipk
    cmdline(curl_url)
    return 1

# Function to get the path to a file
def find_file(root_dir, file_name):
    for root, dirs, files in os.walk(root_dir):
        if file_name in files:
            return os.path.join(root, file_name)
    return "Not_Found"

# Function to get paths to all sub folders in a route directory
def list_subdirectories(root_directory):
    subdirectories = []
    for root, dirs, files in os.walk(root_directory):
        for directory in dirs:
            subdirectories.append(os.path.join(root, directory))
    return subdirectories

file_count = 0
              
if len(sys.argv) < 3:
    print("Please provide the package list yaml file and path to the root dirctory where the ipks are stored.")
    print("Usage: python push_package.py <package_list_file_name.yaml> <ipk root directory>")
    exit()

ipk_root_dir = sys.argv[2]

package_feed_uris = get_package_feed_uris()
if package_feed_uris == None:
    exit()

password = get_password(package_feed_uris)
if password == None:
    exit()

exit()
password = "X-JFrog-Art-Api:%s" % password
package_list_yaml = sys.argv[1]
#Open yaml file to read recipe name
with open(package_list_yaml, 'r') as outfile:
    data = yaml.load(outfile, Loader=SafeLoader)

for recipe in data['Recipes']:
    if 'Packages' in data['Recipes'][recipe]:
        file_count += len(data['Recipes'][recipe]['Packages'])

cpu_count = multiprocessing.cpu_count()
p = multiprocessing.Pool(cpu_count)
jfrog_path = package_feed_uris +'/'+data['Globals']['Product']
if data['Globals']['Layer'] != None:
    jfrog_path += "/" + data['Globals']['Layer']
if data['Globals']['Release'] != None:
    jfrog_path += "/" + data['Globals']['Release'] + "/"


upload_counter = 0
final_file_list = []
path_list = list_subdirectories(ipk_root_dir)
path_list.append(ipk_root_dir)
for recipe, value in data['Recipes'].items():
    if 'Packages' in data['Recipes'][recipe]:
        # Find the ipk location
        ipk_path = ""
        for file in data['Recipes'][recipe]['Packages']:
            for path in path_list:
                file_name = os.path.join(path, file)
                if os.path.exists(file_name):
                    final_file_list.append(file_name)
if len(final_file_list) < 1:
    exit()
# Upload a single file first to avoid conflict
# in path creation in the cloud while doing parallel uploads.
print("File count:%d"%len(final_file_list))
push_package(final_file_list[0], jfrog_path, password)

jfrog_path_list = [jfrog_path for file_name in final_file_list]
password_list = [password for file_name in final_file_list]
#print("file_list_length:%d, jfrog_list_length:%d " % (len(file_list), len(jfrog_path_list)))
upload_counter += sum(list(p.starmap(push_package, zip(final_file_list, jfrog_path_list, password_list))))
print("Uploaded: %d/%d" % (upload_counter, file_count))
