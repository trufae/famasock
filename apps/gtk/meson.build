project('famasock-gtk', ['vala', 'c'], version: '0.2.0', meson_version: '>=0.61')
gtk = dependency('gtk4', version: '>=4.8')
json = dependency('json-glib-1.0', version: '>=1.6')
threads = dependency('threads')
math = meson.get_compiler('c').find_library('m')
repo = meson.project_source_root() / '../..'
rust_dir = repo / 'target/release'
rust = meson.get_compiler('c').find_library('famasock', dirs: rust_dir)
headers = include_directories('../../crates/famasock/include')
core_sources = files('src/famasock.vapi', 'src/core.vala')
executable('famasock-gtk', core_sources + files('src/main.vala', 'src/tcp-client.vala'),
  dependencies: [gtk, json, threads, rust, math], include_directories: headers,
  build_rpath: rust_dir,
  install_rpath: get_option('prefix') / get_option('libdir'), install: true)
if host_machine.system() == 'linux'
  install_data(rust_dir / 'libfamasock.so', install_dir: get_option('libdir'))
endif
install_data('org.radare.famasock.gtk.desktop', install_dir: get_option('datadir') / 'applications')
smoke = executable('core-smoke', core_sources + files('tests/core-smoke.vala'),
  dependencies: [json, threads, rust], include_directories: headers, build_rpath: rust_dir)
test('desktop-core', smoke, timeout: 60)
