#Function to execute commands in device shell
def vcc_cmdline(command):
    from subprocess import PIPE, Popen
    process = Popen(args=command, stdout=PIPE, stderr=PIPE, shell=True)
    # If the command fails locally, the error message must be collected
    # from the stderr of Popen.
    msg2 = process.stderr.read()
    # The variable msg will have the response from the remote server, it can
    # either be a success or failure message with details.
    msg = process.communicate()[0]
    #bb.warn("""Executing VCC command: %s""" % command)

    # In case of a local curl command failure, process.returncode will be non-zero
    if process.returncode:
        # Collect the local failure message
        msg = str(msg2)
    return  process.returncode, msg

# Helper function to remove a file
def vcc_unlink_file(file_path):
    import errno
    if os.path.exists(file_path):
        try:
            os.unlink(file_path)
        except OSError as err:
            if err.errno == errno.ENOENT:
                bb.warn("Link already removed.." + file_path + "\n")
            else:
                raise

# Add "task_dep" to the deps list of the "task" so that
# the "task_dep" would be forced to run before "task"
def set_task_dep(d, task, task_dep):
    deps = d.getVarFlag(task, "deps", False)
    deps.append(task_dep)
    d.setVarFlag(task, "deps", deps)

# Helper function to add custom functions to prefuncs/postfuncs
# list of a task.
def vcc_inject_function(d, task_name, list_name, func_name, run_first = True):
    if run_first == True:
        d.prependVarFlag(task_name, list_name, func_name + " ")
    else:
        d.appendVarFlag(task_name, list_name, " " + func_name )

# Helper function to get the value of a key from a dict
def validate_key(parent, key):
    if parent != None and key in parent:
        return parent[key]
    else:
        return None

# Function to select the correct yaml conf for a recipe
# This returns both the yaml file name and yaml conf 
def get_recipe_yaml_conf(d, recipe):
    import os
    import yaml
    from yaml.loader import SafeLoader

    yaml_conf_dict = d.getVar("YAML_CONFIG", True)
    yaml_layer_paths = yaml_conf_dict.keys()

    for path in yaml_layer_paths:
        yaml_conf = yaml_conf_dict.get(path)

        if yaml_conf != None: 
            if 'Recipes' in yaml_conf and isinstance(yaml_conf['Recipes'], dict):
                if recipe in yaml_conf['Recipes']:
                    return path, yaml_conf
        else:
            bb.warn("invalid yaml file in path %s" % path)

    return None, None

def create_yaml_config_header(d):
    #Dictionary template to generate the yaml file
    globals_dict = {'Globals':{'Layer':{}, 'Product':{}, 'Release':{}},
                    'Recipes':{}
                   }
    if bb.data.inherits_class("packagegroup", d):
        globals_dict["Globals"]["Layer"] = d.getVar("PACKAGE_ARCH", True).replace("%s-"%d.getVar("MACHINE", True), "")
        globals_dict["Globals"]["Release"] = d.getVar("PV", True)
    else:
        #globals_dict["Globals"]["Layer"] = d.getVar("LAYER_EXTENSION", True)
        globals_dict["Globals"]["Layer"] = "platform"
        globals_dict["Globals"]["Release"] = d.getVar("CCSP_GIT_BRANCH", True)
    globals_dict["Globals"]["Product"] = d.getVar("MACHINE", True) + "-release"

    return globals_dict

# Function to read the yaml manifest from meta layer paths.
def load_yaml_files_from_layer_paths(d):
    import os
    import yaml
    from yaml.loader import SafeLoader
  
    # Load the yaml configs for layers
    layer_dirs = d.getVar("BBLAYERS", True).split()
    yaml_conf_dict = {}

    for directory in layer_dirs:
        if not os.path.isdir(directory):
            bb.warn(f"Warning: {directory} is not a valid directory.")
            continue
        meta_layer_name = directory.split(os.path.sep)[-1]
        yaml_name = "%s-%s.yaml"%(d.getVar("MACHINE", True), meta_layer_name)
        filepath = os.path.join(directory, yaml_name)

        try:
            if os.path.exists(filepath):
                with open(filepath, 'r') as file:
                    yaml_conf = yaml.safe_load(file)
                    if "Globals" in yaml_conf:
                        yaml_conf_dict[filepath] = yaml_conf

        except Exception as e:
            bb.warn(f"Error loading {filepath}: {e}")
    return yaml_conf_dict

# Function to load the manifest files from meta-rdk-vcc/manifests folder
def load_meta_layer_yaml_files(d, conf_dict):
    import os
    import yaml
    from yaml.loader import SafeLoader

    # Get the list of file names which are already loaded from meta layers and manifests folder.
    loaded_files = [yaml_path.split(os.path.sep)[-1] for  yaml_path in conf_dict.keys()]
    
    # Create the list of expected file names for all the bblayers present
    # Expected file name is in the format "{MACHINE}-{meta-layer-name}.yaml"
    layer_dirs = d.getVar("BBLAYERS", True).split()
    yaml_list = ["%s-%s.yaml"%(d.getVar("MACHINE", True),layer_dir.split(os.path.sep)[-1]) for layer_dir in layer_dirs]

    files_dir = os.path.join(d.getVar("RDKROOT", True), "meta-rdk-vcc", "manifests")
    for yaml_file in yaml_list:
        yaml_path = os.path.join(files_dir, yaml_file)
        # Load the yaml conf from the file if one exists.
        if os.path.exists(yaml_path):
            if yaml_file in loaded_files:
                bb.warn("The manifest %s is already loaded from meta layer, ignoring the file in %s"%(yaml_file, files_dir))
            else:
                with open(yaml_path, "r") as f:
                    conf_dict[yaml_path] = yaml.load(f, Loader=SafeLoader)


# Function to set values to the yaml manifest.
def update_yaml_file(d, recipe, key, value):
    import os
    import yaml
    from yaml.loader import SafeLoader

    # The get_recipe_yaml_conf returns (yaml_path, yaml_conf) tuple,
    # Select the yaml_path and ignore the yaml_conf
    yaml_file_path = get_recipe_yaml_conf(d, recipe)[0]

    if yaml_file_path != None:
        try:
            yaml_conf = None
            with open(yaml_file_path, 'r') as f:
                yaml_conf = yaml.safe_load(f)    
            if yaml_conf != None:
                tmp_recipe = yaml_conf['Recipes'][recipe]
                tmp_recipe[key] = value
                # Write the updated data back to the file
                with open(yaml_file_path, 'w') as f:
                    yaml.dump(yaml_conf, f, default_flow_style=False)
                    bb.warn("Saving file:%s, key:%s, value:%s"%(yaml_file_path, key, value))    
                return True
        except Exception as e:
            bb.warn(f"Error writing {yaml_file_path}: {e}")

    return False


# Read the sha256sum from donestamp file
def get_ipk_donestamp_SHA256sum(d, done_file_path):
    import pickle
    try:
        stamp_data = {}
        with open(done_file_path, 'rb') as file:
            stamp_data = pickle.load(file)
        # Print the parsed data
        for key, value in stamp_data.items():
            if key == "sha256":
                return value
    except Exception as e:
        #bb.warn("get_ipk_donestamp_SHA256sum: Could not find file:%s\n"%done_file_path)
        return None

# function to get the list of ipks and there checksums for a recipe   
def get_recipe_section_from_index_file(d, pn):
    import json
    new_index_file = os.path.join(d.getVar("TMPDIR", True), "Packages.json")
    with open(new_index_file, 'r') as f1:
        json1 = json.load(f1)
        if pn in json1:
            return json1[pn]

# Iterate all the yaml files and create list of all unique paths to the
# corresponding Packages info files in artifactory repository.
def create_package_index_file_list(d):
    # Set to store unique strings
    unique_strings = set()
    conf_dict = d.getVar("YAML_CONFIG", True)
    # Iterate over dictionary items
    for file_path, data in conf_dict.items():
        try:
            # Extract the required fields from an already-parsed dictionary
            globals_section = data.get("Globals", {})
            product = globals_section.get("Product", "").strip()
            layer = globals_section.get("Layer", "").strip()
            release = globals_section.get("Release", "").strip()

            if product and layer and release:
                unique_strings.add(f"{product}/{layer}/{release}")

        except Exception as e:
            bb.error(f"Error processing config in {file_path}: {e}")

    # Convert set to a sorted list
    unique_list = sorted(unique_strings)

    # Print the unique list
    bb.warn("Package info file paths: "%unique_list)
    return unique_list

# Function to read password form .netrc file for host
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

# Function to download a package index file from a specific path
# in jfrog artifactory repository
def jfrog_download_index_file(d, repo_file_path, output_file_path):
    host_name = d.getVar("RDK_ARTIFACTS_URL", True).split("/")[0]
    password = get_password(host_name)
    if password == None:
        bb.error("Could not read password for %s.."%host_name)
        return -1
    password = "X-JFrog-Art-Api:%s" % password

    base_url = d.getVar("PACKAGE_FEED_URIS", True)
    jfrog_path = base_url + '/' + repo_file_path + '/' + "Packages"
    curl_url = 'curl -H ' + '"' + password + '"' + ' -XGET ' + '"' + jfrog_path+ '"'  + ' --output ' + output_file_path
    err, msg = vcc_cmdline(curl_url)
    if err:
        # In case of a local curl command failure, err will be non-zero
        msg = str(msg).split("curl:")[1].strip()
    bb.warn("Downloading %s"%(jfrog_path))
    return err

# Function to parse the Package index file and create a dict of
# recipes in the following structure:
#  "recipe_name_1": {
#        "ipk_name_1.ipk": "Checksum_1",
#         .
#         .
#        "ipk_name_n.ipk": "Checksum_n",
#    },
#    .
#    .
#    "recipe_name_n": {
#        "ipk_name_1.ipk": "Checksum_1",
#         .
#         .
#        "ipk_name_n.ipk": "Checksum_n",
#    },

def get_filename_and_SHA256sum(file_path):
    import re
    result = {}

    with open(file_path, 'r') as file:
        content = file.read().strip()
    # Split the file into sections based on one or more blank lines
    sections = re.split(r'\n\s*\n', content)
    for section in sections:
        filename = None
        SHA256sum = None
        recipe = None
        # Process each line in the section
        for line in section.splitlines():
            # Skip continuation lines (if any)
            if line.startswith(' '):
                continue
            if ':' in line:
                key, value = line.split(':', 1)
                key = key.strip()
                value = value.strip()
                if key == "OE":
                    recipe = value
                if key == "Filename":
                    filename = value
                elif key == "SHA256sum":
                    SHA256sum = value
            # Only add if both filename and SHA256sum are found
            if recipe and filename and SHA256sum:
                if recipe not in result:
                    result[recipe] = {}
                result[recipe][filename] = SHA256sum
                break
    return result

# Download and combine all Packages files from the repository to from 
# the local "Packages" info file in WORKDIR.
def init_package_index_data(d):
    import json

    tmp_output_file = os.path.join(d.getVar("TMPDIR", True), "Packages_temp")
    new_index_file = os.path.join(d.getVar('TMPDIR', True), ".Packages")
    # Iterate all the yaml files and create list of all unique paths to the
    # corresponding Package index files in artifactory repository.
    index_file_paths = create_package_index_file_list(d)
    index_data = {}
    with open (new_index_file, "w") as json_out:
        for file_path in index_file_paths:
            # Download the Package file from jfrog
            err = jfrog_download_index_file(d, file_path, tmp_output_file)
            if err == 0:
                # Append index data from Package file to the
                # combined packages info dict
                index_data.update(get_filename_and_SHA256sum(tmp_output_file))
                vcc_unlink_file(tmp_output_file)

        # Create the "Packages" info dict file where key is the recipe name 
        # "recipe_name":{
        #                   "ipk_name_1": "checksum_1"
        #                   "ipk_name_n": "checksum_n"
        #               },
        sorted_items = sorted(index_data.items())
        index_data = dict(sorted_items)
        json.dump(index_data, json_out)

    old_index_file = os.path.join(d.getVar('TMPDIR', True), "Packages.json")
    vcc_unlink_file(old_index_file)
    os.rename(new_index_file, old_index_file)



def filter_files_by_version(ipk_dict, version_to_find, revision):
    """
    Filters a list of filenames to find those containing a matching base version.

    This function intelligently handles full Yocto PV strings (e.g., "v2.11.2+git...")
    by extracting the base version ("v2.11.2") before searching.

    Args:
        ipk_dict (dict): A dictionary where keys are IPK filenames.
        version_to_find (str): The full version string to search for.

    Returns:
        list: A new list containing only the matching filenames.
    """
    import re

    if not version_to_find:
        return None

    version_str = str(version_to_find)
    base_version = version_str.split('+')[0] if '+' in version_str else version_str
    safe_version = re.escape(base_version)

    # Match version bounded by non-alphanumeric chars
    version_pattern = re.compile(r'[^a-zA-Z0-9]' + safe_version + r'[^a-zA-Z0-9]')

    # Build revision pattern: match "-r0", "-r1", etc. followed by "_" (before arch)
    revision_pattern = None
    if revision:
        safe_revision = re.escape(str(revision))
        revision_pattern = re.compile(r'-' + safe_revision + r'_')

    bb.warn(f"Searching for base version '{base_version}' revision '{revision}' (derived from '{version_to_find}')")

    matching_files = []
    for ipk_name in ipk_dict.keys():
        if not re.search(version_pattern, ipk_name):
            continue
        # If revision specified, also filter by revision
        if revision_pattern and not re.search(revision_pattern, ipk_name):
            continue
        matching_files.append(ipk_name)

    return matching_files

# Function to create the url to download all the ipk files for
# module from jfrog repository.
def setup_package_url(d, ipk_dict, version):
    # The get_recipe_yaml_conf returns (yaml_path, yaml_conf) tuple,
    # Select the yaml_conf and ignore the yaml_path
    yaml_conf = get_recipe_yaml_conf(d, d.getVar("PN"))[1]
    layer = yaml_conf["Globals"]["Layer"] 
    release = yaml_conf["Globals"]["Release"] 
    product = yaml_conf["Globals"]["Product"] 

    path = product
    if layer != None:
        path += "/%s" % layer
    if release != None:
        path += "/%s" % release

    repo_url = d.getVar("PACKAGE_FEED_URIS", True)
    urls = ""
    revision = d.getVar("PR", True)
    matching_ipks = filter_files_by_version(ipk_dict, version, revision)
    if not matching_ipks:
        bb.error("Recipe %s doesnt have matching ipk files for version %s in the index file." % (d.getVar("PN", True), version))
        return
    # Construct the SRC_URI data
    for file_name in matching_ipks:
        urls += os.path.join(repo_url, path, file_name) + ";name=%s;subdir=%s " %(file_name, d.getVar("D", True))
    # Set SRC_URI variable
    d.setVar("SRC_URI", urls)
    recipe = d.getVar("PN", True)
    #bb.warn ("recipe=%s;SRC_URI=%s" %(d.getVar("PN", True), d.getVar("SRC_URI", True)))

# Check if any ipks for the package is updated in the 
# artifactory repo by comparing the sha256sum in the Packages.json
# with donestamp file in the downloads folder.
def package_is_updated(d, pn, recipe_dict):
    import json

    if pn in recipe_dict:
        for ipk_name, sha256sum in recipe_dict[pn].items():
            donestamp_name = os.path.join(d.getVar('DL_DIR'), "%s.done"%ipk_name)
            done_sha256sum = get_ipk_donestamp_SHA256sum(d, donestamp_name)
            if done_sha256sum != sha256sum and done_sha256sum != None:
                bb.warn("!!!! Change in package detected recipe=%s;ipk=%s;sha256sum=%s;done_sha256sum=%s;" %(pn, ipk_name, sha256sum, done_sha256sum))
                return True
    return False

def get_updated_recipes_list(d):
    import json
    package_index_file = os.path.join(d.getVar('TMPDIR', True), "Packages.json")
    updated_recipes = []
    with open(package_index_file, "r") as pkg_idx:
        recipe_dict = json.load(pkg_idx)

        for pn in recipe_dict:
            # Check if any ipks for the package is updated in the artifactory repo
            if package_is_updated(d, pn, recipe_dict):
                updated_recipes.append(pn)
    return updated_recipes

def force_update_ipk(d, pn):
    sstate_clean_cachefiles(d)
    d.setVarFlag('do_vccprocess', 'nostamp', '1')
    bb.warn("Update forced for %s" % (pn))

def clean_recipe_state(d, build_flag):
    build_stat_filename = os.path.join(os.path.split(d.getVar("WORKDIR", True))[0], "last_build_status")
    if os.path.exists(build_stat_filename):
        build_stat = open(build_stat_filename, "r")
        last_build = eval(build_stat.readline())
        if last_build != build_flag:
            bb.warn("Build type changed , cleaning...{}<->{}".format(last_build, build_flag))
            build_stat.close()
            if os.path.exists(build_stat_filename):
                os.unlink(build_stat_filename)
            build_stat = open(build_stat_filename, "w")
            build_stat.write(str(build_flag))
            build_stat.close()
            d.setVarFlag("do_fetch", "nostamp", "1")
            #d.setVarFlag("do_vccprocess", "nostamp", "1")
            sstate_clean_cachefiles(d)
        else:
            build_stat.close()
            #bb.warn("No need to clean as build type is not changed..")
    else:
        if os.path.exists(os.path.split(d.getVar("WORKDIR", True))[0]):
            build_stat = open(build_stat_filename, "w")
            build_stat.write(str(build_flag))
            build_stat.close()   

def do_get_latest_tag(d):
    # Function to get the latest git tag and set SRCREV
    import os
    import subprocess

    # Navigate to the source directory
    src_dir = d.getVar("S")
    os.chdir(src_dir)
    #bb.warn("Navigated to source directory: %s" % src_dir)
    is_git_repo = os.path.isdir('.git')
    # Fetch the latest tag using git
    if is_git_repo:
        latest_tag = subprocess.check_output(["git", "describe", "--tags", "--abbrev=0"], encoding="utf-8").strip()
        # Update SRCREV to point to the tag
    else:
        bb.fatal("The source directory is not a git repository")
        d.setVar("SRCREV", None)
    # Log the latest tag
    bb.warn(f"Latest Git tag found: {latest_tag}")
    return latest_tag

def set_srcrev(d, srcrev_value):
    """
    Set SRCREV variable in BitBake datastore, inferring correct variable name from recipe.
    
    Args:
        d: BitBake datastore object
        srcrev_value: String value to set as SRCREV
    """
    if not srcrev_value:
        bb.warn("Empty SRCREV value provided")
        return

    # Infer package name and source URL from recipe
    pn = d.getVar('PN')
    src_uri = d.getVar('SRC_URI')
    if not 'git://' in src_uri:
        bb.debug("SRC_URI does not contain a git source, skipping SRCREV setting")
        return
    d.delVarFlag('do_fetch', 'file-checksums')
    # Find the git URL and extract name parameter
    var_name = None
    if src_uri:
        for uri in src_uri.split():
            if uri.startswith('git://') or 'git+' in uri:
                name = ""
                url_params = uri.split(";")
                for url_param in url_params:
                    if url_param.startswith("name="):
                        name = url_param.split("=")[1]
                        break
                
                # Check in priority order
                attempts = []
                if name != '' and pn:
                    attempts.append("SRCREV_%s_pn-%s" % (name, pn))
                if name != '':
                    attempts.append("SRCREV_%s" % name)
                if pn:
                    attempts.append("SRCREV_pn-%s" % pn)
                attempts.append("SRCREV")
                
                # Use existing variable or first priority option
                for attempt in attempts:
                    existing_value = d.getVar(attempt, True)
                    if existing_value and existing_value != "INVALID":
                        var_name = attempt
                        break
                
                if not var_name:
                    var_name = attempts[0] if attempts else "SRCREV"
                break
    
    # Fallback to SRCREV_FORMAT or plain SRCREV
    if not var_name:
        srcrev_format = d.getVar('SRCREV_FORMAT')
        if srcrev_format:
            import re
            var_pattern = r'\$\{([^}]+)\}'
            variables = re.findall(var_pattern, srcrev_format)
            if variables:
                var_name = f'SRCREV_{variables[0]}'
            else:
                var_name = "SRCREV"
        else:
            var_name = "SRCREV"
    
    # Set the variable
    d.setVar(var_name, srcrev_value)
    bb.debug(2, f"Set {var_name} to {srcrev_value}")
    
    # Validate the value is reasonable
    if srcrev_value not in ['${AUTOREV}', 'AUTOINC'] and len(srcrev_value) < 7:
        bb.warn(f"SRCREV '{srcrev_value}' seems too short for a git hash")
    
    # Clear any cached values that might be affected
    d.delVar('SRCREV_CACHED')
    
    # Force re-evaluation of SRC_URI checksums if needed
    src_uri = d.getVar('SRC_URI')
    d.setVar("PV", srcrev_value)