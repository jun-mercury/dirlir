/* /etc/machine-id: a real file on the host (NixOS and Ubuntu alike — NOT a
 * symlink into the nix store, which the provision mask would already
 * break), and absent from the shim's minimal /etc. Visible => leak. */
#if __has_include("/etc/machine-id")
#error host-etc-visible
#endif

int main(void) {
    return 0;
}
