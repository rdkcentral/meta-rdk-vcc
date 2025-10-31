inherit vcc_base
inherit vcc_create_manifest

# Fuction to iterate through the RDEPENDS variable and update the version-revision values
python update_rdepends_var(){
    pn = d.getVar('PN', True)
    # The get_recipe_yaml_conf returns (yaml_path, yaml_conf) tuple,
    # Select the yaml_conf and ignore the yaml_path
    yaml_config = get_recipe_yaml_conf(d, pn)[1]
    new_pkg_list = []
    if yaml_config != None:
        # Read the existing list which is in the format: "pkg1 (=1.10-r0) pkg2 (=1.2-r1) pkg3 (1.0-r0) ..." 
        rdepends = d.getVar("RDEPENDS_%s" % pn)
        # Extract all the package names into a separate list : [pkg1, pkg2, pkg3  ..."]
        pkgs = [pkg for pkg in rdepends.split() if not "(" in pkg]
        for pkg in pkgs:
            if not pkg in yaml_config["Recipes"]:
                #raise Exception("Could not find package(%s) in yaml..." % pkg)
                return
            new_pkg_list.append(pkg)
            # Read pv from yaml
            pv = validate_key(yaml_config["Recipes"][pkg], "Version")
            if pv == None:
                raise Exception("No version specified for package(%s) in yaml..." % pkg)
                return
                       
            pv = "(=%s)" % (pv)
            new_pkg_list.append(pv)
        d.setVar("RDEPENDS_%s" % pn, " ".join(new_pkg_list))
}

def write_layer_manifest(d, mode = "package"):

    import yaml
    from yaml.loader import SafeLoader

    pn = d.getVar('PN', True)
    out_name = os.path.join(d.getVar('DEPLOY_DIR_IMAGE', True), "%s.yaml" % pn)
    rdepends_str = "%s %s"%(d.getVar("RDEPENDS_%s"%pn, True),pn)
    rdepends_list = [item.strip() for item in rdepends_str.split()]
    rdepends_list = list(dict.fromkeys(rdepends_list))
    rdepends_list.sort()

    if mode == "package":
        # Open and read the coponent yaml conf for the current package group.
        component_file_name = os.path.join(d.getVar("TMPDIR", True), "yaml_components", pn + ".yaml")
        if not os.path.exists(component_file_name):
            bb.warn("Could not find component file for package group %s.."% pn)
            return

        out_conf = create_yaml_config_header(d)

        with open(component_file_name, "r") as in_file:
            conf = yaml.load(in_file, Loader=SafeLoader)
            del conf[pn]["BBPath"]
            out_conf["Recipes"][pn] = conf[pn]

        component_dir = os.path.join(d.getVar("TMPDIR", True), "yaml_components")
        bb.utils.mkdirhier(os.path.dirname(out_name))
        yaml.dump(out_conf, out_file, default_flow_style=False)
    elif mode == "source":
        # Create the main yaml file with global section and include recipies that are part of package group.
        vcc_do_create_long_list_yaml(d, out_name, includes_list = rdepends_list)

        # Create the build depends yaml file with all the recipes that are excluded in the above yaml file.
        ext_name = os.path.join(d.getVar('DEPLOY_DIR_IMAGE', True), "%s_build_depends.yaml" % pn)
        create_excludes_list_yaml(d, ext_name, excludes_list = rdepends_list)
    else:
        bb.warn("Invalid mode..")

python vcc_make_release_do_make_layer_release(){
    write_layer_manifest(d, mode = "package")
}

python vcc_make_release_do_make_dev_release(){
    write_layer_manifest(d, mode = "source")
}

#python (){
#    # Add the update function to the "prefuncs" list of do_package tasks to make
#    # sure that it is executed only once. This way we can avoid running the function
#    # everytime the recipe is parsed.
#    #vcc_inject_function(d, "do_package", "prefuncs", "update_rdepends_var")
#    #vcc_inject_function(d, "do_package_setscene", "prefuncs", "update_rdepends_var")
#    vcc_inject_function(d, "do_package_qa", "prefuncs", "vcc_make_release_do_write_layer_manifest")
#}

addtask do_make_layer_release
addtask do_make_dev_release
EXPORT_FUNCTIONS do_make_layer_release do_make_dev_release