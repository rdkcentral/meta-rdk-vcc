# This bbappend is to support the of vcc package mode process
#
# The do_package task of glibc requires the SUPPORTED file to identify the
# supported locales. This file is part of the source tree and need to be
# stored in the WORKDIR during the build. Since the source is not fetched during
# vcc package mode process, this file has to be copied to the WORKDIR explicitly
# before the do_package task performs. To achieve this, the bbappend is doing the
# following:
#
#  1. Since the SUPPORTED file is not part of any ipks by default, this bbappend adds
#     the file to the localedef ipk generated from this recipe during the source mode build.
#
#  2. During the package mode processing, extract the dev ipk to D  and copy this file
#     to the WORKDIR folder.
#

# During source mode build , copy the file to D and add it to the localedef ipk
do_install_append() {
    install -m 0755 ${WORKDIR}/SUPPORTED ${D}/
}

FILES_localedef += " /SUPPORTED "

# During package mode build, after the ipk extraction, copy this file
# to WORKDIR as part of do_vccprocess.
do_vccprocess[postfuncs] += " install_supported_list "

install_supported_list() {
    cp -f ${D}/SUPPORTED ${WORKDIR}/
}

# No need to compile and regenerate the binary locale files as
# they can be extracted from the pregenerated ipk packages in package mode.
python disable_binary_locale_generation() {
    if d.getVar("ENABLE_BINARY_LOCALE_GENERATION") != None:
        value = d.getVar("ENABLE_BINARY_LOCALE_GENERATION")
        if value == "1":
            d.setVar("GLIBC_INTERNAL_USE_BINARY_LOCALE", 'precompiled')
            d.setVar("ENABLE_BINARY_LOCALE_GENERATION", "0")
}

# Add the function to the VCC_CALLBACK_FUNCS list so that it would be
# triggered when the recipe parsing is completed in vcc package mode.
VCC_CALLBACK_FUNCS = " disable_binary_locale_generation "