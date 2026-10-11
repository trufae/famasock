[CCode (cheader_filename = "famasock.h")]
namespace Native {
    [CCode (cname = "famasock_version")]
    public unowned string version ();
    [CCode (cname = "famasock_crypto_info")]
    public unowned string crypto_info ();
    [CCode (cname = "famasock_qr_code")]
    public unowned string qr_code (string text);
    [CCode (cname = "famasock_open_desktop")]
    public void* open_desktop (string path, string name, out unowned string? error);
    [CCode (cname = "famasock_command")]
    public unowned string command (void* handle, string json);
    [CCode (cname = "famasock_next_event")]
    public unowned string? next_event (void* handle);
    [CCode (cname = "famasock_string_free")]
    public void string_free (void* text);
    [CCode (cname = "famasock_shutdown")]
    public void shutdown (void* handle);
    [CCode (cname = "famasock_free")]
    public void free (void* handle);
}
