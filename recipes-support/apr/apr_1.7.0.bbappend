# This bbappend is to support the of vcc package mode process
#
# The "apr_sysroot_preprocess" function preprocesses
# some files before packaging them in to the ipk files during source
# mode build. It also copies some files from the source folder to the
# recipe image folder and those files would inturn be copied to the sysroot-destdir
# folder by the do_populate_sysroot task. In vcc package mode none of these
# activities are required as  vcc package mode uses  pre-built ipk files and 
# all required files are directly installed in to the image folder from
# ipk so that nothing is needed to be copied from source folder either.

# The Below function is to clear the "apr_sysroot_preprocess" from the 
# SYSROOT_PREPROCESS_FUNCS list to prevent it from running during vcc
# package mode.
python disable_apr_sysroot_preprocess() {
    sysroot_funcs = d.getVar("SYSROOT_PREPROCESS_FUNCS", True)
    sysroot_funcs = sysroot_funcs.replace("apr_sysroot_preprocess", "")
    d.setVar("SYSROOT_PREPROCESS_FUNCS", sysroot_funcs)
}

# Add the function to the VCC_CALLBACK_FUNCS list so that it would be 
# triggered when the recipe parsing is completed in vcc package mode.
VCC_CALLBACK_FUNCS = " disable_apr_sysroot_preprocess "
