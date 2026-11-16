inherit vcc_sdk_deploy
inherit vcc_create_manifest

def vcc_clean_function_list(d, task_name, list_name):
    d.setVarFlag(task_name, list_name, " ")

# Helper function to enable a task.
def enable_task(d, task):
    if d.getVarFlag(task, "noexec", False) != None:
        d.delVarFlag(task, "noexec")

# Helper function to enable a task.
def disable_task(d, task):
    d.setVarFlag(task, "noexec", "1")

def is_task_enabled(d, task):
    status = d.getVarFlag(task, "noexec", False)
    if status != None:
        if status == "1":
            return False
    return True

python vcc_clean(){
    vcc_clean_internal(d)
}

def disable_unused_previous_tasks(d, task_name, except_list):
    pn = d.getVar('PN', True)
    task_stack = []
    task_stack.append(task_name)
    processed_tasks = []
    while task_stack:
        cur_task = task_stack.pop()
        if not cur_task in except_list:
            disable_task(d, cur_task)
        processed_tasks.append(cur_task)
        deps = d.getVarFlag(cur_task, 'deps', False)
        if deps != None:
            for dep in deps:
                if not (dep in task_stack or dep in processed_tasks):
                    task_stack.append(dep)

python create_conf_dirs(){
    dvar = d.getVar("D", True)
    conf_dir = os.path.join(dvar, "etc")
    if not os.path.exists(conf_dir):
        bb.utils.mkdirhier(os.path.join(conf_dir, "modules-load.d"))
        bb.utils.mkdirhier(os.path.join(conf_dir, "modprobe.d"))
    else:
        if not os.path.exists(os.path.join(conf_dir, "modules-load.d")):
            bb.utils.mkdirhier(os.path.join(conf_dir, "modules-load.d"))
        if not os.path.exists(os.path.join(conf_dir, "modprobe.d")):
            bb.utils.mkdirhier(os.path.join(conf_dir, "modprobe.d"))

}

python rename_binaries(){
    install_dir = d.getVar("D", True)
    bpn = d.getVar("BPN", True)
    link_list = []
    for root, dirs, files in os.walk(install_dir):
        for file in files:
            src_path = os.path.join(root, file)
            if src_path.endswith(".%s"% bpn):
                image_path = src_path.replace(install_dir, "")
                rename = True
                for flag in d.getVarFlags("ALTERNATIVE_TARGET"):
                    if image_path == d.getVarFlag("ALTERNATIVE_TARGET", flag):
                        rename = False
                        break
                if rename:
                    new_path = src_path.replace(".%s"% bpn, "")
                    os.rename(src_path, new_path)
                    src_path = new_path

            if os.path.islink(src_path):
                link_list.append(src_path)
    for link in link_list:
        target = os.readlink(link)
        if target.endswith(".%s"% bpn):
            link_dir = os.path.dirname(link)
            target_path = os.path.join(link_dir, target)
            if not os.path.exists(target_path):
                target = target.replace(".%s"% bpn, "")
                os.unlink(link)
                os.symlink(target, link)
}

def clean_pseudo_directory(d):
    import shutil
    import os

    pseudo_dir = os.path.join(d.getVar("WORKDIR"), "pseudo")
    if os.path.exists(pseudo_dir):
        bb.warn("Cleaning pseudo directory: %s" % pseudo_dir)
        shutil.rmtree(pseudo_dir)
    else:
        bb.note("No pseudo directory to clean at: %s" % pseudo_dir)

def do_vcc_pkg_mode(d, recipe):
    # Prevent calling the default get_srcrev function from SRCPV in package mode.
    # If the build user does not have access to the source repo, get_srcrev will
    # cause fetch error. Also, in vcc package mode , SRCREV is not required 
    d.setVar("SRCPV", "")
    # Skip the condition check in kirkstone as SRCREV is not required in vcc package mode. 
    d.setVar("__BBSEENSRCREV", "1")
    #setup_package_url_internal(d)
    pn = d.getVar('PN', True)
    version = validate_key(recipe, 'Version')

    # Build is false ,need to disable some of the tasks.
    if version != None:
        d.setVar('PV', version)
    #d.setVar("BB_STRICT_CHECKSUM", "0")
    d.setVar("MULTILIB_SCRIPTS", "")
    disable_task(d, "do_populate_lic")

    if bb.data.inherits_class("kernel", d) or bb.data.inherits_class("module", d):
        # For kernel module packages , add the below function to create the etc folder
        # and its sub folders in case they are not existing. This is required because
        # the function "split_kernel_module_packages" tries to remove those
        # folders without checking their existance and this will lead to a build error
        # if they are absent.
        vcc_inject_function(d, "do_vccprocess", "postfuncs", "create_conf_dirs")
        
        # For kernel package mode, disable the devel_create task
        # as it is not required in package mode.
        # The do_kernel_devel_create task is used to create the kernel devel ipk
        disable_task(d, "do_kernel_devel_create")

    if bb.data.inherits_class('update-alternatives', d):
        vcc_inject_function(d, "do_vccprocess", "postfuncs", "rename_binaries")
    
    vcc_inject_function(d, "do_clean", "postfuncs", "vcc_clean")
    vcc_inject_function(d, "do_package", "prefuncs", "add_insane_skip")

    tasklist = []
    for e in bb.data.keys(d):
       if d.getVarFlag(e, 'task', False):
           tasklist.append(e)
    # First disable do_install and all the default tasks which are executed before it.
    # Do not disable do_prepare_recipe_sysroot as this is required to keep the 
    # order in which the recipes are built as per their build dependencies.
    if "do_install" in tasklist:
        disable_unused_previous_tasks(d, "do_install", except_list=["do_prepare_recipe_sysroot"])

    # Add do_vccprocess in to the chain in such a way that all the default
    # tasks which were waiting on do_install would be waiting for do_vccprocess now onwards.
    task_added = False
    for task in tasklist:
        deps = d.getVarFlag(task, "deps", False)
        if "do_install" in deps:
            deps.remove("do_install")
            deps.append("do_vccprocess")
            d.setVarFlag(task, "deps", deps)
            task_added = True
            
    if task_added:
        # Add do_prepare_recipe_sysroot to the deps list of do_vccprocess 
        # to make sure that the do_prepare_recipe_sysroot rus before the
        # do_vccprocess. This order is important in some cases where the prefuncs
        # or postfuncs of vcc_process uses some commands form the recipe's sysroot
        # and these commands are installed by do_prepare_recepe_sysroot task.
        set_task_dep(d, "do_vccprocess", "do_prepare_recipe_sysroot")
    else:
        # In some cases the do_prepare_recipe_sysroot would not be there in the 
        # active task list (eg: package groups), in this situation add the 
        # do_vccprocess as a dependency for do_package to make sure that it is
        # executed before do_package.
        if "do_package" in tasklist and is_task_enabled(d, "do_package"):
            set_task_dep(d, "do_package", "do_vccprocess")

    skip_tasks = d.getVar("VCC_SKIP_TASKS", True)
    if skip_tasks != None:
        for task in skip_tasks.split():
            disable_task(d, task)

    enable_task(d, "do_package_write_ipk")
    enable_task(d, "do_prepare_recipe_sysroot")
    enable_task(d, "do_populate_sysroot")
    enable_task(d, "do_cleansstate")
    enable_task(d, "do_clean")
    enable_task(d, "do_cleanall")
    enable_task(d, "do_build")

    funcs = d.getVar("VCC_CALLBACK_FUNCS", True)
    if funcs != None:
        for f in funcs.split():
            bb.build.exec_func(f, d)
    # This is for a corner case where archiver class is used with release pipeline
    # we check if do_unpack_and_patch is in the tasklist and disable it
    if d.getVarFlags("do_unpack_and_patch") is not None:
        disable_task(d, "do_unpack_and_patch")
    


python remove_ipk_from_deploy() {
    # Get the ipk file list from the ipk write manifest file
    ipk_manifest_name = d.getVar("SSTATE_MANFILEPREFIX", True) + ".package_write_ipk"
    if os.path.exists(ipk_manifest_name):
        with open(ipk_manifest_name, "r") as ipk_list:
            ipk_list = ipk_list.readlines()
            for line in ipk_list:
                ipk_file = line.strip("\n")
                if ipk_file.endswith(".ipk"):
                    vcc_unlink_file(ipk_file)
}

python add_insane_skip() {
    """
    Add the 'already-stripped' to the INSANE_SKIP variable for the current recipe.
    This is to avoid the 'already-stripped' error during the build process.
    """
    bb.warn("Adding 'already-stripped' to INSANE_SKIP for the current recipe.")
    pn = d.getVar('PN', True)
    insane_skip = d.getVar('INSANE_SKIP:' + pn) or ""
    insane_skip += " already-stripped "
    d.setVar('INSANE_SKIP:' + pn, insane_skip)
}

def extract_ipk_filenames(src_uri_string):
    """
    Parses a SRC_URI string to find and extract .ipk filenames.
    Args:
        src_uri_string (str): The full SRC_URI string.
    Returns:
        list: A list of strings, containing only the filenames with an .ipk extension.
    """
    ipk_filenames = []
    import os
    from urllib.parse import urlparse
    # 1. Split the string by spaces to get individual entries.
    # This is the core simplification.
    entries = src_uri_string.split()

    # 2. Loop through each potential file or URL.
    for entry in entries:
        # 3. Strip off any Yocto parameters (e.g., ';unpack=0').
        base_entry = entry.split(';', 1)[0]
        # 4. Use os.path.basename to get the final filename component.
        filename = os.path.basename(urlparse(base_entry).path)
        # 5. Check if the extracted filename has the '.ipk' extension.
        if filename.endswith('.ipk'):
            ipk_filenames.append(filename)
            
    return ipk_filenames

def vcc_install_ipk(d):
    import os
    
    pn = d.getVar("PN")
    ipk_list = extract_ipk_filenames(d.getVar("SRC_URI", True))
    source_path = d.getVar("DL_DIR")
    install_dir = d.getVar("D")
    if not ipk_list:
        bb.error(f"No IPK files found in SRC_URI for recipe {pn}.")
        return
    for file_name in ipk_list:
        source_name = os.path.join(source_path, file_name)
        if not os.path.isfile(source_name):
            bb.error(f"IPK file {source_name} not found. Skipping.")
            continue

        try:
            cmd = (
                f"ar x {source_name} && "
                f"tar -C {install_dir} --no-same-owner -xpf data.tar.xz && "
                f"rm -f data.tar.xz control.tar.* debian-binary"
            )

            vcc_cmdline(cmd)
        except Exception as e:
            bb.error(f"Failed to install {file_name}: {str(e)}")

# Function to clean the ipk files from the deploy/ipk/.. folder
# this is triggered for do_cleansstate/cleanall/clean tasks.
def vcc_clean_internal(d):
    import errno
    import shutil
    import os

    project_name = d.getVar("PN", True)

    #d.setVarFlag("do_vccfetch", "nostamp", "1")
    #d.setVarFlag("do_vccprocess", "nostamp", "1")

    # Get the ipk file list from the ipk write manifest file
    #ipk_manifest_name = d.getVar("SSTATE_MANFILEPREFIX", True) + ".package_write_ipk"
    #if os.path.exists(ipk_manifest_name):
    #    with open(ipk_manifest_name, "r") as ipk_list:
    #        ipk_list = ipk_list.readlines()
    #        for line in ipk_list:
    #            ipk_file = line.strip("\n")
    #            if ipk_file.endswith(".ipk"):
    #                vcc_unlink_file(ipk_file)
    #    #Remove the ipk manifest file
    #    vcc_unlink_file(ipk_manifest_name)

    # Remove the package info file
    package_info_name = os.path.join(d.getVar("PKGDATA_DIR", True), project_name)
    if os.path.exists(package_info_name):
        try:
            bb.warn("Removing info file.." + package_info_name + "\n")
            os.unlink(package_info_name)
        except OSError as err:
            if err.errno == errno.ENOENT:
                bb.warn("File already removed.." + package_info_name + "\n")
            else:
                raise

    
    target_path = os.path.join(d.getVar("PKGDATA_DIR", True), "runtime")

    if os.path.exists(target_path):
        # Remove the info files from runtime folder.
        files = os.listdir(target_path)
        pn_file_names = [file_name for file_name in files if project_name in file_name]
        for file_name in pn_file_names:
            target_name = os.path.join(target_path, file_name)
            link_name = target_name.replace('runtime', 'runtime-reverse')
            if os.path.exists(target_name):
                #bb.warn("Removing info file.." + target_name + "\n")
                try:
                    os.unlink(target_name)
                except OSError as err:
                    if err.errno == errno.ENOENT:
                        bb.warn("File already removed.." + target_name + "\n")
                    else:
                        raise
            if os.path.exists(link_name):
                try:
                    os.unlink(link_name)
                except OSError as err:
                    if err.errno == errno.ENOENT:
                        bb.warn("File already removed.." + link_name + "\n")
                    else:
                        raise

    # Remove the packagedata manifest file
    packagedata_manifest_name = d.getVar("SSTATE_MANFILEPREFIX", True) + ".packagedata"
    if os.path.exists(packagedata_manifest_name):
        try:
            os.unlink(packagedata_manifest_name)
        except OSError as err:
            if err.errno == errno.ENOENT:
                bb.warn("File already removed.." + packagedata_manifest_name + "\n")
            else:
                raise
    # Remove the ipk files from download dirctory
    download_dir = d.getVar("DL_DIR", True)
    ipk_dict = get_recipe_section_from_index_file(d, project_name)
    for file_name in ipk_dict.keys():
        file_path = os.path.join(download_dir, file_name)
        vcc_unlink_file(file_path)

do_rootfs[recrdeptask] += " do_package_write_ipk "
def vcc_fetch_internal(d):

    #Set the "SRC_URI" variable with the urls of packages to do the fetch
    #setup_package_url_internal(d)
    # Fetch the package files 
    vcc_multi_fetch(d)

# Function to fetch multiple package files in parallel 
def vcc_multi_fetch(d):
    import multiprocessing 

    def split_into_batches(lst, batch_size=10):
        for i in range(0, len(lst), batch_size):
            yield lst[i:i + batch_size]

    src_uri = (d.getVar('SRC_URI') or "").split()
    if len(src_uri) == 0:
        return

    batch_size = 100
    for url_batch in split_into_batches(src_uri, batch_size=batch_size):
        processes = []
        for file_uri in url_batch:
            p = multiprocessing.Process(target=vcc_fetch_package, args=(d, file_uri, ))
            processes.append(p)
            p.start()
        for process in processes:
            process.join()

# Do sequential fetch as per the file_uri
def vcc_fetch_package(d, file_uri):

    src_uri = file_uri.split()
    try:
        fetcher = bb.fetch2.Fetch(src_uri, d)
        fetcher.download()
    except bb.fetch2.BBFetchException as e:
        bb.fatal(str(e))

def vcc_populate_lic(d):
    destdir = os.path.join(d.getVar('LICENSE_DIRECTORY'), d.getVar('PN'))
    info = {}
    info["PV"] = d.getVar("PV")
    info["PR"] = d.getVar("PR")
    info["LICENSE"] = d.getVar("LICENSE")
    bb.utils.mkdirhier(destdir)
    with open(os.path.join(destdir, "recipeinfo"), "w") as f:
        for key in sorted(info.keys()):
            f.write("%s: %s\n" % (key, info[key]))


def vcc_do_vccprocess_internal(d):
    vcc_fetch_internal(d)
    clean_pseudo_directory(d)
    vcc_install_ipk(d)
    vcc_populate_lic(d)
    # Package mode, Copy the input yaml section for the recipe
    # to the output yaml manifest
    create_yaml_section_pkg_mode(d, d.getVar("PN", True))

python vcc_package_deploy_do_package_mode() {
    recipe = d.getVar("PN", True)
    if update_yaml_file(d, recipe, 'Build', False) is True:
        bb.warn("Recipe mode switched to package mode, please run bitbake " + recipe)
    else:
        bb.warn("This recipe is missing from the yaml file")
}

def vcc_set_source_mode(d):
    recipe = d.getVar("PN", True)
    if update_yaml_file(d, recipe, 'Build', True) is True:
        # Some packages requires the kernel shared source files for build.
        # In such cases the source mode build for kernel needs to be enabled so that
        # the work-shared folder would be populated with all required kernel source files.
        if bb.data.inherits_class("kernel-arch", d):
            kernel_recipe = d.getVar("PREFERRED_PROVIDER_virtual/kernel", True)
            if kernel_recipe != None:
                if update_yaml_file(d, kernel_recipe, 'Build', True) is True:
                    bb.warn("Kernel recipe mode switched to source mode for %s"%recipe)
                else:
                    bb.warn("Recipe %s requires kernel sources and recipe mode for kernel is source mode by default"%recipe)

        bb.warn("Recipe mode switched to source mode, please run bitbake " + recipe)
    else:
        bb.warn("This recipe is missing from the yaml file")

python vcc_package_deploy_do_source_mode() {
    vcc_set_source_mode(d)
}

python vcc_package_deploy_do_vccprocess() {
    vcc_do_vccprocess_internal(d)
}

do_vccprocess[dirs] = "${D}"

addtask do_package_mode 
addtask do_source_mode 
addtask do_vccprocess

EXPORT_FUNCTIONS do_vccprocess do_package_mode do_source_mode
