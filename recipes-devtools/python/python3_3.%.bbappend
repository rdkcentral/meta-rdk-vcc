# This bbappend is to support the of vcc package mode process
#
# The "py_package_preprocess" function in the PACKAGE_PREPROCESS_FUNCS
# list variable is to remove the build host path references from certain files
# before packaging them into the ipk files. The vcc package mode would be using
# these pre-built ipks and the updated files are directly installed in to the
# recipe image folder and hence the "py_package_preprocess" is not required to run.

# Below, the function disable_py_package_preprocess clears the
# "py_package_preprocess" from the PACKAGE_PREPROCESS_FUNCS list to prevent
# it from running in vcc package mode.

python disable_py_package_preprocess() {
    sysroot_funcs = d.getVar("PACKAGE_PREPROCESS_FUNCS", True)
    sysroot_funcs = sysroot_funcs.replace("py_package_preprocess", "")
    d.setVar("PACKAGE_PREPROCESS_FUNCS", sysroot_funcs)
}

# Add the function to the VCC_CALLBACK_FUNCS list so that it would be 
# triggered when the recipe parsing is completed in vcc package mode.
VCC_CALLBACK_FUNCS = " disable_py_package_preprocess "

PACKAGES += " ${PN}-sysconfigdata "
FILES_${PN}-sysconfigdata = "/sysconfigdata/*"

do_install_append_class-target() {
    install -d ${D}/sysconfigdata/
    install -d ${D}/sysconfigdata/python-sysconfigdata
    sysconfigfile=`find ${D}${libdir}/python${PYTHON_MAJMIN}/ -name _sysconfigdata_*.py`
    temp_file_name="temp_$(basename "$sysconfigfile")"
    cp $sysconfigfile ${D}/sysconfigdata/$temp_file_name
    cp -rf ${D}${libdir}/python-sysconfigdata/* ${D}/sysconfigdata/python-sysconfigdata/
    sed -e 's,${TMPDIR},TMPDIR,g' -i ${D}/sysconfigdata/$temp_file_name
    sed -e 's,${TMPDIR},TMPDIR,g' -i ${D}/sysconfigdata/python-sysconfigdata/_sysconfig*.py
}

do_vccprocess[postfuncs] += " install_sysconfigdata_files "

install_sysconfigdata_files() {
    
    cp -r ${D}/sysconfigdata/temp_* ${D}${libdir}/python${PYTHON_MAJMIN}/

    sed -e 's,TMPDIR,${TMPDIR},g' -i ${D}${libdir}/python${PYTHON_MAJMIN}/temp_*
    temp_file_name=`find ${D}${libdir}/python${PYTHON_MAJMIN}/ -name temp_*.py`
    temp_file_name=$(basename "$temp_file_name")
    sysconfigfile=$(echo "$temp_file_name" | sed 's/^temp_//')
    mv ${D}${libdir}/python${PYTHON_MAJMIN}/temp_*  ${D}${libdir}/python${PYTHON_MAJMIN}/$sysconfigfile

    mkdir -p ${D}${libdir}/python-sysconfigdata
    cp ${D}/sysconfigdata/python-sysconfigdata/* ${D}${libdir}/python-sysconfigdata
    sed -e 's,TMPDIR,${TMPDIR},g' -i ${D}${libdir}/python-sysconfigdata/*
}


