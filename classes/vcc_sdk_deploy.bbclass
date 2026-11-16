
#addtask do_vccprocess_sdk before do_populate_sysroot
#addtask do_vccprocess_sdk before do_build
python vcc_sdk_deploy_do_vccprocess_sdk() {
    vcc_deploy_sdk(d)
}

#EXPORT_FUNCTIONS do_vccprocess_sdk
#do_vccprocess_sdk[nostamp] = "1"
#do_rootfs[recrdeptask] += " do_vccprocess_sdk "
#do_rootfs[recrdeptask] += " do_prepare_recipe_sysroot "
#do_prepare_recipe_sysroot[recrdeptask] += " do_vccprocess_sdk "

def vcc_deploy_sdk(d):
    import os
    import shutil
    from subprocess import PIPE, Popen
    
    tar_extract_root_dir = os.path.join(d.getVar("TMPDIR", True), "tar_tmp_" + d.getVar("PN", True))
    if os.path.exists(tar_extract_root_dir):
        shutil.rmtree(tar_extract_root_dir)
    bb.utils.mkdirhier(tar_extract_root_dir)

    in_tar_gz = os.path.join(d.getVar('RDKROOT', True), "..", "sdk_tarballs" ,d.getVar("PN", True)+"_sdk.tar.gz")
    if not os.path.exists(in_tar_gz):
        shutil.rmtree(tar_extract_root_dir)
        return

    out_dir = tar_extract_root_dir
    cmd = 'tar -xvzf %s -C %s' % (in_tar_gz, out_dir)
    vcc_cmdline(cmd)

    sysroot_components_dir_src = os.path.join(tar_extract_root_dir, "sysroots-components")
    sysroot_components_dir_dst = os.path.join(d.getVar("COMPONENTS_DIR", True), d.getVar("PACKAGE_ARCH", True), d.getVar("PN", True))
    if os.path.exists(sysroot_components_dir_dst):
        shutil.rmtree(sysroot_components_dir_dst)
    shutil.copytree(sysroot_components_dir_src, sysroot_components_dir_dst)

    manifest_name = d.getVar("SSTATE_MANFILEPREFIX", True) + ".populate_sysroot"
    bb.utils.mkdirhier(os.path.dirname(manifest_name))
    with open(manifest_name, "w") as manifest:
        for (dir_path, dir_names, file_names) in os.walk(sysroot_components_dir_dst):
            for file in file_names:
                manifest.write(os.path.join(dir_path, file) + "\n")

    #remove the temp dir
    shutil.rmtree(tar_extract_root_dir)


def vcc_do_create_sdk_tarball(d, pkg, sysroot_dir, sysroot_native_dir, components_dir):
    import os
    import shutil
    from subprocess import PIPE, Popen

    in_sdk_dir = components_dir + "/" + pkg
    if os.path.exists(in_sdk_dir):
        child_list = os.listdir(in_sdk_dir)
        if len(child_list) == 0 or (len(child_list) == 1 and "sysroot-providers" in child_list):
            bb.warn("vcc_do_create_sdk_tarball: not creating the sdk tarball")
            return
    else:
        return

    tar_input_root_dir = os.path.join(d.getVar("TMPDIR", True), "tar_tmp_" + pkg)
    if os.path.exists(tar_input_root_dir):
        shutil.rmtree(tar_input_root_dir)
    bb.utils.mkdirhier(tar_input_root_dir)
    
    sysroots_components_dir = os.path.join(tar_input_root_dir, "sysroots-components")
    bb.warn("sysroots-components path(len:%d): "% len(os.listdir(in_sdk_dir)) + in_sdk_dir)
    shutil.copytree(in_sdk_dir, sysroots_components_dir, symlinks=True, ignore_dangling_symlinks = True)
    
    out_dir = os.path.join(d.getVar('RDKROOT', True), "..", "sdk_tarballs_out")
    bb.utils.mkdirhier(out_dir)
    out_tar_gz = os.path.join(out_dir, pkg + "_sdk.tar.gz")
    vcc_cmdline('tar -chvzf %s -C %s .' % (out_tar_gz, tar_input_root_dir))
    #remove the temp dir
    shutil.rmtree(tar_input_root_dir)

def skip_populate_sysroot(d):
    pn = d.getVar('PN', True)
    data = d.getVar("YAML_CONFIG", True)
    d.setVar("VCC_BUILD", "1")
    if data != None and 'Recipes' in data and data['Recipes'] != None and pn in data['Recipes']:
        if data['Recipes'][pn]["Build"] == False:
            d.setVar("VCC_BUILD", "0")
            return True
    return False

#do_populate_sysroot_prepend() {
#    if skip_populate_sysroot(d) == True:
#        return
#}

#do_populate_sysroot_setscene_prepend() {
#    if skip_populate_sysroot(d) == True:
#        return
#}
