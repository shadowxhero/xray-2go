import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

SCRIPT = Path(__file__).resolve().parents[1] / 'xray_2go.sh'


class LifecycleRegression(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xray2go-test-')
        self.d = Path(self.tmp.name)
        self.home = self.d / 'home'
        self.home.mkdir()
        self.state = {
            'version': 2, 'name': '东京 测试', 'server': '2001:db8::9',
            'cdn': 'cdn.example.com', 'cdn_port': 443, 'subscription_port': 18431,
            'subscription_path': 'fixture-token', 'subscription_enabled': True,
            'tunnel_mode': 'quick', 'tunnel_domain': 'old.trycloudflare.com',
            'argo_port': 18080,
        }
        self.config = {'inbounds': [
            {'tag': 'xhttp-reality', 'port': 18433, 'protocol': 'vless',
             'settings': {'clients': [{'id': '11111111-1111-4111-8111-111111111111'}]},
             'streamSettings': {'network': 'xhttp', 'security': 'reality',
                'realitySettings': {'target': 'xhttp.example.com:443', 'serverNames': ['xhttp.example.com'], 'privateKey': 'fixture'}}},
            {'tag': 'argo-entry', 'port': 18080, 'protocol': 'vless',
             'settings': {'clients': [{'id': '11111111-1111-4111-8111-111111111111'}]},
             'streamSettings': {'network': 'tcp'}},
            {'tag': 'raw-reality', 'port': 18432, 'protocol': 'vless',
             'settings': {'clients': [{'id': '11111111-1111-4111-8111-111111111111', 'flow': 'xtls-rprx-vision'}]},
             'streamSettings': {'network': 'raw', 'security': 'reality',
                'realitySettings': {'dest': 'raw.example.com:443', 'serverNames': ['raw.example.com'], 'privateKey': 'fixture'}}},
            {'tag': 'vless-ws', 'port': 3002, 'protocol': 'vless', 'settings': {'clients': [{'id': '11111111-1111-4111-8111-111111111111'}]}, 'streamSettings': {'network': 'ws'}},
            {'tag': 'vmess-ws', 'port': 3003, 'protocol': 'vmess', 'settings': {'clients': [{'id': '11111111-1111-4111-8111-111111111111'}]}, 'streamSettings': {'network': 'ws'}},
        ], 'outbounds': [{'protocol': 'freedom'}]}
        (self.home / 'state.json').write_text(json.dumps(self.state))
        (self.home / 'config.json').write_text(json.dumps(self.config))
        (self.home / 'public.key').write_text('fixture-public-key')
        self.addCleanup(self.tmp.cleanup)

    def run_shell(self, body, ok=True):
        # The baseline has an unconditional menu. Source its function definitions only.
        loader = 'source <(sed \'${/^menu$/d;}\' "$SCRIPT")\n'
        setup = '''
work_dir="$CASE/home"
config_dir="$work_dir/config.json"
client_dir="$work_dir/url.txt"
state_file="$work_dir/state.json"
init_dir="$CASE/init.d"
systemd_dir="$CASE/systemd"
run_dir="$CASE/run"
mkdir -p "$init_dir" "$systemd_dir" "$run_dir"
derive_public_key() { cat "$work_dir/public.key"; }
validate_xray_config() { jq -e '.inbounds|length>0' "$1" >/dev/null; }
'''
        r = subprocess.run(['bash', '-c', loader + 'set -e\n' + setup + body],
            env={**os.environ, 'SCRIPT': str(SCRIPT), 'CASE': str(self.d)},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def nodes(self):
        text = (self.home / 'url.txt').read_text()
        encoded = (self.home / 'sub.txt').read_text()
        self.assertEqual(base64.b64decode(encoded).decode(), text)
        return [x for x in text.splitlines() if x]

    def test_four_names_are_distinct_and_uuid_flow_ipv6_survive(self):
        self.run_shell('generate_subscription\n')
        ns = self.nodes()
        self.assertEqual(len(ns), 4)
        self.assertEqual([unquote(urlsplit(x).fragment) for x in ns[:3]],
            ['东京 测试-RAW-Reality', '东京 测试-XHTTP-Reality', '东京 测试-VLESS-Argo'])
        raw = urlsplit(ns[0]); q = parse_qs(raw.query)
        self.assertEqual(raw.hostname, '2001:db8::9')
        self.assertEqual(raw.username, '11111111-1111-4111-8111-111111111111')
        self.assertEqual(q['flow'], ['xtls-rprx-vision'])
        vm = json.loads(base64.b64decode(ns[3][8:]))
        self.assertEqual(vm['ps'], '东京 测试-VMess-Argo')
        self.assertEqual(vm['scy'], 'aes-128-gcm')

    def test_quick_domain_sync_updates_both_nodes_and_is_idempotent(self):
        (self.home / 'argo.log').write_text('https://older.trycloudflare.com\nhttps://fresh.trycloudflare.com\n')
        self.run_shell('generate_subscription\nsync_subscription\nsync_subscription\n')
        ns = self.nodes()
        self.assertEqual(parse_qs(urlsplit(ns[2]).query)['host'], ['fresh.trycloudflare.com'])
        self.assertEqual(json.loads(base64.b64decode(ns[3][8:]))['host'], 'fresh.trycloudflare.com')
        self.assertEqual(json.loads(base64.b64decode(ns[3][8:]))['ps'], '东京 测试-VMess-Argo')

    def test_old_quick_log_cannot_overwrite_fixed_domain(self):
        self.state.update(tunnel_mode='token', tunnel_domain='fixed-b.example.com')
        (self.home / 'state.json').write_text(json.dumps(self.state))
        (self.home / 'argo.log').write_text('https://stale.trycloudflare.com\n')
        self.run_shell('generate_subscription\nsync_subscription\n')
        ns = self.nodes()
        self.assertEqual(parse_qs(urlsplit(ns[2]).query)['sni'], ['fixed-b.example.com'])
        self.assertEqual(json.loads(base64.b64decode(ns[3][8:]))['sni'], 'fixed-b.example.com')

    def test_direct_port_update_matches_transport_not_array_position(self):
        self.run_shell('set_direct_port raw 18434\n')
        c = json.loads((self.home / 'config.json').read_text())
        self.assertEqual([i['port'] for i in c['inbounds']], [18433, 18080, 18434, 3002, 3003])
        self.assertEqual(urlsplit(self.nodes()[0]).port, 18434)

    def test_invalid_port_leaves_config_and_subscription_unchanged(self):
        self.run_shell('generate_subscription\n')
        before = [(self.home / n).read_bytes() for n in ('config.json', 'url.txt', 'sub.txt')]
        r = self.run_shell('set_direct_port raw 70000\n', ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(before, [(self.home / n).read_bytes() for n in ('config.json', 'url.txt', 'sub.txt')])

    def test_nginx_only_serves_exact_subscription_path(self):
        self.d.chmod(0o711)
        self.home.chmod(0o711)
        self.run_shell('generate_subscription\nwrite_nginx_config\n')
        conf = self.home / 'nginx.conf'
        nginx = subprocess.run(['nginx', '-t', '-c', str(conf)], capture_output=True, text=True)
        self.assertEqual(nginx.returncode, 0, nginx.stderr)
        p = subprocess.Popen(['nginx', '-c', str(conf), '-g', 'daemon off;'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (p.terminate(), p.wait(timeout=5)) if p.poll() is None else None)
        import urllib.request, urllib.error, time
        for _ in range(30):
            try:
                body = urllib.request.urlopen('http://127.0.0.1:18431/fixture-token', timeout=.3).read(); break
            except OSError: time.sleep(.05)
        else: self.fail('subscription listener never started')
        self.assertEqual(base64.b64decode(body), (self.home / 'url.txt').read_bytes())
        for path in ('/config.json', '/state.json', '/fixture-token/config.json', '/'):
            with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen('http://127.0.0.1:18431'+path)
            self.assertEqual(e.exception.code, 404)
            e.exception.close()

    def test_service_definitions_include_supervision_for_all_components(self):
        self.run_shell('write_runtime_helpers\nwrite_openrc_services\nwrite_systemd_services\n')
        for name in ('xray2go-core', 'xray2go-tunnel', 'xray2go-sub', 'xray2go-sync'):
            p = self.d / 'init.d' / name
            r = subprocess.run(['sh', '-c', 'source() { :; }; . "$1"; test "$supervisor" = supervise-daemon && test "$respawn_delay" -ge 5', 'test', str(p)])
            self.assertEqual(r.returncode, 0, name)
            s = (self.d / 'systemd' / (name+'.service')).read_text()
            self.assertIn('Restart=always', s)
            self.assertIn('StartLimitIntervalSec=0', s)
        self.assertNotIn('rc-service', (self.home/'sync-loop.sh').read_text())

    def test_each_reality_link_uses_its_own_key(self):
        self.config['inbounds'][0]['streamSettings']['realitySettings']['privateKey'] = 'xhttp-private'
        self.config['inbounds'][2]['streamSettings']['realitySettings']['privateKey'] = 'raw-private'
        (self.home / 'config.json').write_text(json.dumps(self.config))
        self.run_shell('derive_public_key() { case "$1" in raw-private) echo raw-public;; xhttp-private) echo xhttp-public;; *) return 1;; esac; }\ngenerate_subscription\n')
        ns = self.nodes()
        self.assertEqual(parse_qs(urlsplit(ns[0]).query)['pbk'], ['raw-public'])
        self.assertEqual(parse_qs(urlsplit(ns[1]).query)['pbk'], ['xhttp-public'])

    def test_failed_tunnel_restart_restores_credentials_and_state(self):
        self.state.update(tunnel_mode='token', tunnel_domain='good.example.com')
        (self.home/'state.json').write_text(json.dumps(self.state))
        (self.home/'tunnel.token').write_text('good-fixture-token')
        (self.d/'new-token').write_text('bad-fixture-token')
        self.run_shell('generate_subscription\n')
        before = (self.home/'state.json').read_bytes()
        r = self.run_shell('service_action() { return 1; }\nset_tunnel token bad.example.com "$CASE/new-token"\n', ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(before, (self.home/'state.json').read_bytes())
        self.assertEqual((self.home/'tunnel.token').read_text(), 'good-fixture-token')

    def test_http_success_without_owned_nginx_is_not_a_healthy_migration(self):
        self.run_shell('generate_subscription\n')
        r = self.run_shell('curl() { cp "$work_dir/public/sub.txt" "${@: -1}"; }\nsleep() { :; }\nsubscription_probe\n', ok=False)
        self.assertNotEqual(r.returncode, 0)

    def test_protocols_detect_reads_real_inbounds(self):
        self.config['inbounds'] = [i for i in self.config['inbounds'] if i.get('tag') != 'vmess-ws']
        (self.home / 'config.json').write_text(json.dumps(self.config))
        self.run_shell(r'''
out=$(protocols_detect | tr '\n' ' ')
test "$out" = "raw-reality xhttp-reality vless-argo "
''')

    def test_ask_install_protocols_sets_variable_and_keeps_menu_visible(self):
        # 菜单里是直接调用（不是 $(...) 捕获），提示必须真的打印出来，
        # 结果只写进 PROTOCOLS 变量。
        self.run_shell(r'''
out=$(ask_install_protocols <<< "13")
case "$out" in
    *"选择要安装的协议"*) ;;
    *) echo "菜单没打印出来"; exit 1 ;;
esac
case "$out" in
    *"1. VLESS RAW"*) ;;
    *) echo "编号列表没打印出来"; exit 1 ;;
esac
ask_install_protocols <<< "13"
test "$PROTOCOLS" = "raw-reality,vless-argo"
ask_install_protocols <<< ""
test "$PROTOCOLS" = "raw-reality,xhttp-reality,vless-argo,vmess-argo"
''')

    def test_protocols_from_digits_accepts_compact_input(self):
        self.run_shell(r'''
test "$(protocols_from_digits 13)" = "raw-reality,vless-argo"
test "$(protocols_from_digits 31)" = "raw-reality,vless-argo"
test "$(protocols_from_digits 1234)" = "raw-reality,xhttp-reality,vless-argo,vmess-argo"
test "$(protocols_from_digits 1,3)" = "raw-reality,vless-argo"
test "$(protocols_from_digits '1 3')" = "raw-reality,vless-argo"
test "$(protocols_from_digits 11)" = "raw-reality"
test "$(protocols_from_digits "")" = "raw-reality,xhttp-reality,vless-argo,vmess-argo"
! protocols_from_digits 15 >/dev/null 2>&1
! protocols_from_digits abc >/dev/null 2>&1
! protocols_from_digits 0 >/dev/null 2>&1
''')

    def test_protocols_normalize_orders_and_rejects_bad_input(self):
        self.run_shell(r'''
test "$(protocols_normalize "vless-argo,raw-reality" | tr '\n' ' ')" = "raw-reality vless-argo "
! protocols_normalize "" >/dev/null 2>&1
! protocols_normalize "raw-reality,bogus" >/dev/null 2>&1
''')

    def test_subscription_contains_only_enabled_protocols(self):
        self.state['protocols'] = ['raw-reality', 'vless-argo']
        (self.home / 'state.json').write_text(json.dumps(self.state))
        self.run_shell('generate_subscription\n')
        ns = self.nodes()
        self.assertEqual(len(ns), 2)
        self.assertEqual(unquote(urlsplit(ns[0]).fragment), '东京 测试-RAW-Reality')
        self.assertEqual(unquote(urlsplit(ns[1]).fragment), '东京 测试-VLESS-Argo')

    def test_apply_protocols_drops_argo_inbounds_and_stops_tunnel(self):
        self.run_shell(r'''
service_enable() { :; }
service_disable() { printf 'disable %s\n' "$1" >> "$CASE/actions"; }
service_action() { printf 'action %s %s\n' "$1" "$2" >> "$CASE/actions"; }
apply_protocols raw-reality,xhttp-reality
jq -e '.inbounds|map(.tag)|sort == ["raw-reality","xhttp-reality"]' "$work_dir/config.json" >/dev/null
jq -e '.protocols == ["raw-reality","xhttp-reality"]' "$work_dir/state.json" >/dev/null
''')
        actions = (self.d / 'actions').read_text()
        self.assertIn('action xray2go-tunnel stop', actions)
        self.assertIn('disable xray2go-tunnel', actions)

    def test_apply_protocols_adds_missing_reality_back_with_remembered_port(self):
        self.config['inbounds'] = [i for i in self.config['inbounds'] if i.get('tag') != 'raw-reality']
        (self.home / 'config.json').write_text(json.dumps(self.config))
        self.state['protocols'] = ['xhttp-reality']
        self.state['ports'] = {'raw': 18432}
        (self.home / 'state.json').write_text(json.dumps(self.state))
        self.run_shell(r'''
service_enable() { :; }
service_disable() { :; }
service_action() { :; }
new_reality_key() { printf 'fixture-private-key\n'; }
apply_protocols xhttp-reality,raw-reality
jq -e '.inbounds[]|select(.tag=="raw-reality")|.port == 18432' "$work_dir/config.json" >/dev/null
jq -e '.inbounds[]|select(.tag=="raw-reality")|.settings.clients[0].flow == "xtls-rprx-vision"' "$work_dir/config.json" >/dev/null
''')

    def test_validate_survives_busybox_mktemp_without_suffix_support(self):
        # Alpine 默认没有 coreutils：busybox mktemp 只接受以 XXXXXX 结尾的模板，
        # 传 ".validate.XXXXXX.json" 会直接报 "mktemp: : Invalid argument"。
        binary = self.home / 'xray'
        binary.write_text('#!/bin/bash\n[[ "${@: -1}" == *.json ]] || exit 23\n'
                          '[[ -s "${@: -1}" ]] || exit 24\n')
        binary.chmod(0o700)
        (self.home / 'cand').write_text(json.dumps(self.config))
        self.run_shell(r'''
mktemp() {
    case "${@: -1}" in
        *XXXXXX) command mktemp "$@";;
        *) echo 'mktemp: : Invalid argument' >&2; return 1;;
    esac
}
validate_xray_config "$work_dir/cand"
''')
        self.assertEqual(list(self.home.glob('.validate.*')), [])

    def test_validation_passes_json_extension_to_real_core_boundary(self):
        binary = self.home/'xray'
        binary.write_text('#!/bin/bash\n[[ "$*" == *"-format json"* ]] || exit 1\n[[ "${@: -1}" == *.json ]] || exit 23\njq -e . "${@: -1}" >/dev/null\n')
        binary.chmod(0o700)
        (self.home/'candidate-no-extension').write_text(json.dumps(self.config))
        r = subprocess.run(['bash','-c','source "$SCRIPT"; work_dir="$CASE/home"; validate_xray_config "$work_dir/candidate-no-extension"'],
            env={**os.environ,'SCRIPT':str(SCRIPT),'CASE':str(self.d)},capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(list(self.home.glob('.validate.*')),[])

    def test_cdn_change_rebuilds_both_argo_nodes_without_changing_direct_nodes(self):
        self.run_shell('generate_subscription\n')
        direct=self.nodes()[:2]
        self.run_shell('set_cdn 2001:db8::7 8443\n')
        ns=self.nodes()
        self.assertEqual(ns[:2],direct)
        ws=urlsplit(ns[2]);self.assertEqual(ws.hostname,'2001:db8::7');self.assertEqual(ws.port,8443)
        vm=json.loads(base64.b64decode(ns[3][8:]));self.assertEqual(vm['add'],'2001:db8::7');self.assertEqual(vm['port'],'8443')
        self.assertEqual(vm['host'],'old.trycloudflare.com')

    def test_sni_change_only_updates_selected_transport(self):
        original=self.config['inbounds'][2]
        self.run_shell('set_sni xhttp changed.example.com\n')
        cfg=json.loads((self.home/'config.json').read_text())
        self.assertEqual(cfg['inbounds'][2],original)
        self.assertEqual(cfg['inbounds'][0]['streamSettings']['realitySettings']['serverNames'],['changed.example.com'])
        self.assertEqual(parse_qs(urlsplit(self.nodes()[1]).query)['sni'],['changed.example.com'])

    def test_retired_caddy_config_without_service_is_safe_to_skip(self):
        r=self.run_shell('''
check_caddy_owned() { return 0; }
is_openrc() { return 0; }
rc-service() { return 1; }
rc-update() { return 0; }
stop_owned_caddy
''',ok=False)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((self.home/'.caddy-retired').exists())

    def test_default_name_uses_country_and_isp_with_underscores(self):
        out=self.run_shell('''
curl() { printf '{"country_code":"US","isp":"Example ISP"}'; }
resolve_node_name
''').stdout.strip()
        self.assertEqual(out,'US-Example_ISP')

    def test_name_lookup_falls_back_when_first_provider_returns_empty_json(self):
        out=self.run_shell('''
curl() { case "${@: -1}" in *ip.sb*) echo '{}';; *) echo '{"country_code":"US","org":"ExampleISP"}';; esac; }
resolve_node_name
''').stdout.strip()
        self.assertEqual(out,'US-ExampleISP')

    def test_explicit_node_name_never_calls_geolocation(self):
        out=self.run_shell('''
NODE_NAME=Custom-Node
curl() { echo unexpected >&2;return 1; }
resolve_node_name
''').stdout.strip()
        self.assertEqual(out,'Custom-Node')

    def test_upgrade_failure_restores_previous_files(self):
        self.run_shell('generate_subscription\nwrite_nginx_config\n')
        before = {n:(self.home/n).read_bytes() for n in ('state.json','config.json','url.txt','sub.txt')}
        r = self.run_shell('''
install_dependencies() { :; }
service_status() { return 1; }
service_enabled() { return 1; }
is_openrc() { return 0; }
legacy_retire() { :; }
install_runtime_copy() { :; }
configure_services() { :; }
service_action() { return 0; }
service_disable() { :; }
start_services() { return 1; }
upgrade_installation
''', ok=False)
        self.assertNotEqual(r.returncode, 0)
        for n,b in before.items(): self.assertEqual((self.home/n).read_bytes(), b, n)

    def test_rollback_restores_shortcut_and_removes_new_runtime(self):
        shortcut = self.d/'2go'
        shortcut.write_text('#!/bin/sh\necho legacy\n')
        self.run_shell('''
shortcut_path="$CASE/2go"
service_status() { return 1; }
service_enabled() { return 1; }
service_action() { return 0; }
service_disable() { :; }
is_openrc() { return 0; }
backup_installation
b=$(cat "$work_dir/last-backup")
printf 'new runtime' > "$work_dir/runtime.sh"
printf 'new helper' > "$work_dir/sync-loop.sh"
printf 'new shortcut' > "$shortcut_path"
rollback_upgrade "$b"
''')
        self.assertEqual(shortcut.read_text(), '#!/bin/sh\necho legacy\n')
        self.assertFalse((self.home/'runtime.sh').exists())
        self.assertFalse((self.home/'sync-loop.sh').exists())

    def test_internal_fallback_ports_are_reserved_during_install(self):
        r = self.run_shell('validate_install_ports 43013 43011 43012 3001\n', ok=False)
        self.assertNotEqual(r.returncode,0)
        r = self.run_shell('validate_install_ports 43013 3002 43012 8080\n', ok=False)
        self.assertNotEqual(r.returncode,0)
        self.run_shell('port_available() { [ "$1" != 3003 ]; }\nif validate_install_ports 43013 43011 43012 8080; then exit 1;fi\n')

    def test_failed_install_removes_owned_services_and_archives_partial_files(self):
        self.run_shell('''
archive_root="$CASE/archive"
mkdir -p "$archive_root"
touch "$work_dir/.installing"
is_openrc() { return 0; }
for s in "${SERVICES[@]}"; do printf '# Managed by shadowxhero/xray-2go\\n' > "$init_dir/$s"; done
service_action() { :; }
service_disable() { :; }
stop_owned_processes() { :; }
cleanup_failed_install
''')
        self.assertFalse(self.home.exists())
        self.assertEqual(list((self.d/'init.d').iterdir()),[])
        archives=list((self.d/'archive').glob('xray2go-failed-install-*'))
        self.assertEqual(len(archives),1)
        self.assertTrue((archives[0]/'config.json').exists())

    def test_failed_legacy_import_leaves_no_partial_state(self):
        (self.home / 'state.json').unlink()
        vm = base64.b64encode(json.dumps({'add': 'cdn.example.com', 'port': '443', 'ps': 'Legacy', 'host': 'fixed.example.com'}).encode()).decode()
        (self.home / 'url.txt').write_text('vless://11111111-1111-4111-8111-111111111111@[2001:db8::9]:18432?type=tcp\nvmess://'+vm+'\n')
        self.config['inbounds'][1]['settings']['fallbacks'] = [{'dest': 3002}]
        (self.home / 'config.json').write_text(json.dumps(self.config))
        r = self.run_shell('import_caddy_settings() { return 1; }\nload_legacy_state\n', ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.home / 'state.json').exists())

    def test_cli_process_substitution_does_not_lose_runtime_script(self):
        # 断言"输出了脚本里声明的版本"，不绑定具体版本号，升版不必改这条测试。
        expected = re.search(r'^SCRIPT_VERSION=(\S+)$', SCRIPT.read_text(), re.M).group(1)
        r = subprocess.run(['bash', '-c', 'bash <(cat "$SCRIPT") --version'],
            env={**os.environ, 'SCRIPT': str(SCRIPT)}, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), expected)

    def test_caddy_migration_rejects_unrelated_websites(self):
        cf = self.d / 'Caddyfile'
        cf.write_text(':43013 {\n handle /KeepOldPath {\n root * /srv/another-site\n }\n}\n')
        before = (self.home / 'state.json').read_bytes()
        r = self.run_shell('import_caddy_settings "$CASE/Caddyfile"\n', ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(before, (self.home / 'state.json').read_bytes())

    def test_legacy_raw_tcp_and_ipv6_can_change_port_without_touching_argo(self):
        self.config['inbounds'][2]['streamSettings']['network'] = 'tcp'
        (self.home / 'config.json').write_text(json.dumps(self.config))
        self.run_shell('set_direct_port raw 18434\n')
        c = json.loads((self.home / 'config.json').read_text())
        self.assertEqual(c['inbounds'][1]['port'], 18080)
        self.assertEqual(urlsplit(self.nodes()[0]).hostname, '2001:db8::9')
        self.assertEqual(urlsplit(self.nodes()[0]).port, 18434)

    def test_caddy_migration_reads_port_path_and_preserves_credentials(self):
        cf = self.d / 'Caddyfile'
        cf.write_text('{\n auto_https off\n}\n:43013 {\n handle /KeepOldPath {\n root * /etc/xray\n try_files /sub.txt\n }\n}\n')
        before = (self.home / 'config.json').read_bytes()
        self.run_shell('import_caddy_settings "$CASE/Caddyfile"\n')
        s = json.loads((self.home / 'state.json').read_text())
        self.assertEqual(s['subscription_port'], 43013)
        self.assertEqual(s['subscription_path'], 'KeepOldPath')
        self.assertEqual(before, (self.home / 'config.json').read_bytes())

    def test_sync_loop_probes_tunnel_health_each_cycle(self):
        self.run_shell('write_runtime_helpers\n')
        text = (self.home / 'sync-loop.sh').read_text()
        self.assertIn('--sync', text)
        self.assertIn('--health', text)
        # 探测每 6 轮（约 60 秒）一次，避免小内存机器上频繁 fork。
        self.assertIn('n % 6', text)

    def test_tunnel_health_restarts_quick_tunnel_after_three_failed_probes(self):
        self.run_shell(r'''
tunnel_probe() { return 1; }
service_status() { return 0; }
service_action() { printf '%s %s\n' "$1" "$2" >> "$CASE/actions"; }
rm -f "$work_dir/.health-ts"; tunnel_health
rm -f "$work_dir/.health-ts"; tunnel_health
test ! -f "$CASE/actions"
rm -f "$work_dir/.health-ts"; tunnel_health
''')
        self.assertEqual((self.d / 'actions').read_text(), 'xray2go-tunnel restart\n')
        self.assertFalse((self.home / '.health-fails').exists())

    def test_tunnel_health_leaves_manually_stopped_tunnel_alone(self):
        self.run_shell(r'''
tunnel_probe() { return 1; }
service_status() { return 1; }
service_action() { printf '%s %s\n' "$1" "$2" >> "$CASE/actions"; }
printf '2\n' > "$work_dir/.health-fails"
rm -f "$work_dir/.health-ts"
tunnel_health
test ! -f "$CASE/actions"
test ! -f "$work_dir/.health-fails"
''')

    def test_tunnel_health_clears_counter_when_probe_recovers(self):
        self.run_shell(r'''
tunnel_probe() { return 0; }
service_action() { printf '%s %s\n' "$1" "$2" >> "$CASE/actions"; }
printf '2\n' > "$work_dir/.health-fails"
rm -f "$work_dir/.health-ts"
tunnel_health
test ! -f "$work_dir/.health-fails"
test ! -f "$CASE/actions"
''')

    def test_tunnel_health_skips_fixed_tunnel(self):
        self.state.update(tunnel_mode='token', tunnel_domain='fixed.example.com')
        (self.home / 'state.json').write_text(json.dumps(self.state))
        self.run_shell(r'''
tunnel_probe() { printf x >> "$CASE/probes"; return 1; }
service_action() { printf '%s %s\n' "$1" "$2" >> "$CASE/actions"; }
tunnel_health
test ! -f "$CASE/probes"
test ! -f "$CASE/actions"
''')

    def test_tunnel_health_throttles_probe_and_waits_after_restart(self):
        self.run_shell(r'''
tunnel_probe() { printf x >> "$CASE/probes"; return 0; }
date() { printf 1000; }
: > "$CASE/probes"
printf '950\n' > "$work_dir/.health-ts"
tunnel_health
test ! -s "$CASE/probes"
printf '900\n' > "$work_dir/.health-ts"
tunnel_health
test -s "$CASE/probes"
printf '950\n' > "$work_dir/last-renew"
printf '900\n' > "$work_dir/.health-ts"
: > "$CASE/probes"
tunnel_health
test ! -s "$CASE/probes"
''')

    def test_service_memory_targets_are_low_enough_for_small_hosts(self):
        self.run_shell('write_runtime_helpers\nwrite_openrc_services\nwrite_systemd_services\n')
        svc = (self.d / 'init.d' / 'xray2go-core').read_text()
        self.assertIn('GOMEMLIMIT=32MiB', svc)
        self.assertIn('GOGC=20', svc)
        unit = (self.d / 'systemd' / 'xray2go-core.service').read_text()
        self.assertIn('GOMEMLIMIT=32MiB', unit)
        self.assertIn('GOGC=20', unit)
        worker = (self.home / 'tunnel-worker.sh').read_text()
        self.assertIn('GOMEMLIMIT=20MiB', worker)
        self.assertIn('GOGC=15', worker)
        # cloudflared 真正运行前的 export 也要用同一组默认值。
        self.assertIn('ARGO_GOMEMLIMIT:-20MiB', SCRIPT.read_text())
        self.assertIn('ARGO_GOGC:-15', SCRIPT.read_text())

    def test_oom_score_adj_protects_core_and_tunnel(self):
        self.run_shell('write_runtime_helpers\nwrite_openrc_services\nwrite_systemd_services\n')
        for name, adj in (('xray2go-core', '-500'), ('xray2go-tunnel', '-500'),
                          ('xray2go-sync', '500'), ('xray2go-sub', '0')):
            svc = (self.d / 'init.d' / name).read_text()
            self.assertIn(f'echo {adj} > /proc/self/oom_score_adj', svc, name)
            # start_pre 必须始终返回 0，否则 oom_score_adj 不可写时服务会启动失败。
            self.assertIn('return 0', svc.split('start_pre()')[1], name)
            unit = (self.d / 'systemd' / (name + '.service')).read_text()
            self.assertIn(f'OOMScoreAdjust={adj}', unit, name)

    def test_tunnel_probe_uses_cloudflared_log_and_never_touches_network(self):
        log = self.home / 'argo.log'
        log.write_text('INF Registered tunnel connection connIndex=0\n')
        self.run_shell(r'''
curl() { printf x >> "$CASE/net-called"; }
wget() { printf x >> "$CASE/net-called"; }
tunnel_probe old.trycloudflare.com
test ! -f "$CASE/net-called"
''')
        # 隧道被回收：cloudflared 会持续写 "Tunnel not found"。
        log.write_text('INF Registered tunnel connection\n'
                       'ERR Register tunnel error from server side error="Unauthorized: Tunnel not found"\n')
        self.run_shell('! tunnel_probe old.trycloudflare.com\n')
        # 还没注册成功（刚重启）：没有 Registered 就不算活。
        log.write_text('INF Requesting new quick Tunnel on trycloudflare.com...\n')
        self.run_shell('! tunnel_probe old.trycloudflare.com\n')
        # 日志缺失时保守判死，由 180 秒重启缓冲避免误杀。
        log.unlink()
        self.run_shell('! tunnel_probe old.trycloudflare.com\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
