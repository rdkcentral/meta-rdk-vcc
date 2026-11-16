# This bbappend is to support the of vcc package mode process
PACKAGE_PREPROCESS_FUNCS += " backup_cross_compile_wrappers"

 

backup_cross_compile_wrappers() {
    # The following wrappper scripts are used by other recipies during their compilation.
    # These object-introspection wrapper scripts are used for scanning the libraries
    #  produced by other recipies to generate metadata files for language bindings. 
    install -d ${PKGD}/cross_compile/
    # Add the wrappers to package
    install ${D}${bindir}/g-ir-scanner-qemuwrapper ${PKGD}/cross_compile/
    install ${D}${bindir}/g-ir-scanner-wrapper ${PKGD}/cross_compile/
    install ${D}${bindir}/g-ir-compiler-wrapper ${PKGD}/cross_compile/
    install ${D}${bindir}/g-ir-scanner-lddwrapper ${PKGD}/cross_compile/
    # Replace the build host path references with dummy strings.
    sed -e 's,${TMPDIR},TMPDIR,g' -i ${PKGD}/cross_compile/g-ir-scanner-qemuwrapper
    sed -e 's,${TMPDIR},TMPDIR,g' -i ${PKGD}/cross_compile/g-ir-scanner-wrapper
    sed -e 's,${TMPDIR},TMPDIR,g' -i ${PKGD}/cross_compile/g-ir-compiler-wrapper
    sed -e 's,${TMPDIR},TMPDIR,g' -i ${PKGD}/cross_compile/g-ir-scanner-lddwrapper
}

PACKAGES += " ${PN}-cross-compile"

FILES_${PN}-cross-compile = "/cross_compile/*"

install_cross_compile_wrappers() {
    # Replace the dummy strings in wrapper scripts with current build host paths.
    sed -e 's,TMPDIR,${TMPDIR},g' -i ${D}/cross_compile/g-ir-scanner-qemuwrapper
    sed -e 's,TMPDIR,${TMPDIR},g' -i ${D}/cross_compile/g-ir-scanner-wrapper
    sed -e 's,TMPDIR,${TMPDIR},g' -i ${D}/cross_compile/g-ir-compiler-wrapper
    sed -e 's,TMPDIR,${TMPDIR},g' -i ${D}/cross_compile/g-ir-scanner-lddwrapper
    # Install the wrapper scripts.
    install ${D}/cross_compile/g-ir-scanner-qemuwrapper ${D}${bindir}/
    install ${D}/cross_compile/g-ir-scanner-wrapper ${D}${bindir}/
    install ${D}/cross_compile/g-ir-compiler-wrapper ${D}${bindir}/
    install ${D}/cross_compile/g-ir-scanner-lddwrapper ${D}${bindir}/
}

do_vccprocess[postfuncs] += " install_cross_compile_wrappers "