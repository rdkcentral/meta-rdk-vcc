# Tasks and functions to prepare output yaml manifest file
def update_component_yaml_build_flag(recipe, new_build_value):
    import yaml
    yaml_path = os.path.join(d.getVar("TMPDIR", True), "yaml_components", recipe + ".yaml")
    if not os.path.exists(yaml_path):
        create_yaml_section_src_mode(d, recipe)
    # Load existing YAML content
    with open(yaml_path, 'r') as f:
        data = yaml.safe_load(f)

    if recipe not in data:
        raise ValueError(f"Component '{recipe}' not found in YAML file.")

    data[recipe]['Build'] = bool(new_build_value)

    # Write updated YAML back to file
    with open(yaml_path, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

# Function to copy the yaml section from input yaml 
# to the output yaml file. 
def create_yaml_section_pkg_mode(d, recipe):
    import yaml
    from yaml.loader import SafeLoader
    # The get_recipe_yaml_conf returns (yaml_path, yaml_conf) tuple,
    # Select the yaml_conf and ignore the yaml_path
    yaml_config = get_recipe_yaml_conf(d, recipe)[1]
    recipe_conf = yaml_config["Recipes"][recipe]
    conf = {}
    conf[recipe] = recipe_conf
    component_file_name = os.path.join(d.getVar("TMPDIR", True), "yaml_components", recipe + ".yaml")
    bb.warn("Copying yaml section in package mode..")
    os.makedirs(os.path.join(d.getVar("TMPDIR", True), "yaml_components"), exist_ok=True)
    with open(component_file_name, "w") as out_file:
        yaml.dump(conf, out_file, default_flow_style=False)
        # If the recipe section in the input yaml file does not have the BBPath parameter,
        # add the parameter to the output yaml section. This is required to filter the recipe
        # file list for the package when the mask list is prepared for the final yaml file.
        bb_name = d.getVar('FILE')
        bb_name = bb_name.replace(d.getVar('RDKROOT', True) + '/', '')
        out_file.write("  BBPath: %s\n" % bb_name)

# Function to create yaml sections for recipes in source mode

def create_yaml_section_src_mode(d, recipe):
    import os
    component_file_name = os.path.join(d.getVar("TMPDIR", True), "yaml_components", recipe + ".yaml")

    bb.utils.mkdirhier(os.path.dirname(component_file_name))
    with open(component_file_name, "w") as out_file:
        rdk_root = d.getVar('RDKROOT', True)
        bb_name = d.getVar('FILE')
        bb_name = bb_name.replace(rdk_root + '/', '')
        out_file.write("%s:\n" % recipe)
        out_file.write("  Build: true\n")
        out_file.write("  BBPath: %s\n" % bb_name)
        out_file.write("  Version: '%s'\n" % d.getVar('PV'))

# Combine all the component yaml files to form the long list yaml.
def vcc_do_create_long_list_yaml(d, long_list_yaml_name, includes_list = None):
    import yaml
    from yaml.loader import SafeLoader

    globals_dict = create_yaml_config_header(d)

    with open(long_list_yaml_name, 'w') as out_file:
        yaml_components_dir = os.path.join(d.getVar("TMPDIR", True), "yaml_components")
        if not os.path.exists(yaml_components_dir):
            bb.warn("Could not find the component yaml files..")
            return
        if includes_list != None:
            component_file_list = ["%s.yaml"%recipe for recipe in includes_list]
        else:
            component_file_list = os.listdir(yaml_components_dir)
        component_file_list.sort()
        # Combine component yaml files in to the final yaml file
        for comp_file in component_file_list:
            comp_file_path = os.path.join(yaml_components_dir, comp_file)
            if not os.path.exists(comp_file_path):
                bb.warn("Could not find yaml section %s.."%comp_file_path)
                continue
            with open(comp_file_path, 'r') as infile2:
                recipe_data = yaml.load(infile2, Loader=SafeLoader)
                if recipe_data != None:
                    for recipe in recipe_data:
                        globals_dict["Recipes"][recipe] = recipe_data[recipe]

        yaml.dump(globals_dict, out_file, default_flow_style=False)

# Function to create yaml file with sections for all recipes in the yaml-components 
# folder which are not part of the excludes_list argument. No globals section will
# be included in this yaml file.
def create_excludes_list_yaml(d, out_name, excludes_list = None):
    import yaml
    from yaml.loader import SafeLoader
    # Read all file names from yaml-components folder
    yaml_components_dir = os.path.join(d.getVar("TMPDIR", True), "yaml_components")
    if not os.path.exists(yaml_components_dir):
        bb.warn("Could not find the component yaml files..")
        return
    globals_dict = {}
    component_file_list = os.listdir(yaml_components_dir)

    # Remove all those file names from the file list which are part of the excludes list. 
    if excludes_list != None:
        component_file_list = [filename for filename in component_file_list if not filename.replace(".yaml", "") in excludes_list]

    component_file_list.sort()

    # Combine the files in the file list into the output yaml file.
    with open(out_name, 'w') as out_file:
        for file_name in component_file_list:
            component_file_name = os.path.join(yaml_components_dir, file_name)
            with open(component_file_name, 'r') as infile2:
                recipe_data = yaml.load(infile2, Loader=SafeLoader)
                for recipe in recipe_data:
                    if "Packages" in recipe_data[recipe]:
                        globals_dict[recipe] = recipe_data[recipe]
        yaml.dump(globals_dict, out_file, default_flow_style=False)

#Function to get list of dependant packages
#And populate a yaml file based on the packages
python write_final_yaml_manifest() {
    pkg = d.getVar('PN', True)
    long_list_yaml_name = os.path.join(d.getVar('DEPLOY_DIR_IMAGE', True), "%s.yaml" % pkg)
    vcc_do_create_long_list_yaml(d, long_list_yaml_name)
}

python write_meta_layer_yaml_manifests() {
    vcc_do_create_meta_layer_yaml(d)
}

def vcc_do_create_meta_layer_yaml(d):
    import os
    import yaml
    from yaml.loader import SafeLoader

    # Each item in this dictionary represents the entire yaml file data
    # for the corresponding meta layer. Native recipes are filtered out
    # from the yaml file.
    meta_layers_dict = {}

    layer_dirs = d.getVar("BBLAYERS", True).split()
    rdk_root = d.getVar('RDKROOT', True)

    # Initialize the dictionary elements, use the meta layer directory path
    # as key.
    for directory in layer_dirs:
        meta_layer_name = directory.replace(rdk_root + '/', '') + os.sep
        meta_layers_dict[meta_layer_name] = create_yaml_config_header(d)

    yaml_components_dir = os.path.join(d.getVar("TMPDIR", True), "yaml_components")
    component_file_list = os.listdir(yaml_components_dir)
    component_file_list = [comp_file for comp_file in component_file_list if not "-native." in comp_file]
    component_file_list.sort()

    masks_str = ""
    for comp_file in component_file_list:
        comp_file_path = os.path.join(yaml_components_dir, comp_file)
        if not os.path.exists(comp_file_path):
            bb.warn("Could not find yaml section %s.."%comp_file_path)
            continue
        with open(comp_file_path, 'r') as infile2:
            recipe_data = yaml.load(infile2, Loader=SafeLoader)
            if recipe_data != None:
                for recipe in recipe_data:
                    # For each recipe in the component directory, add the yaml section
                    # to the corresponding meta layer yaml file.
                    for key in meta_layers_dict:
                        if recipe_data[recipe]["BBPath"].startswith(key):
                            globals_dict = meta_layers_dict[key]
                            break

                    globals_dict["Recipes"][recipe] = recipe_data[recipe]


    # Write the output yaml file for each metalayer.
    for key in meta_layers_dict:
        globals_dict = meta_layers_dict[key]

        # The output file name would be "machine-metalayer.yaml"
        meta_layer_yaml_name = "%s-%s.yaml" % (d.getVar('MACHINE', True), key.split(os.path.sep)[-2])
        output_yaml_name = os.path.join(d.getVar('DEPLOY_DIR_IMAGE', True), "yaml-manifests", meta_layer_yaml_name)
        if (bool(globals_dict["Recipes"])):
            bb.utils.mkdirhier(os.path.dirname(output_yaml_name))
            with open(output_yaml_name, 'w') as out_file:
                yaml.dump(globals_dict, out_file, default_flow_style=False)

ROOTFS_POSTPROCESS_COMMAND += " write_final_yaml_manifest; write_meta_layer_yaml_manifests;"
