import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'xray_2go.sh'
class InteractionRegression(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='xray2go-ui-');self.addCleanup(self.tmp.cleanup)
        self.d=Path(self.tmp.name)
        (self.d/'state.json').write_text(json.dumps({'server':'2001:db8::1','subscription_port':18431,'subscription_path':'fixture-path','cdn':'cdn.example.com','cdn_port':443,'tunnel_mode':'quick','argo_port':8080,'subscription_enabled':True}))
        (self.d/'config.json').write_text(json.dumps({'inbounds':[{'port':18432},{'port':18433},{'port':3001}]}))
        (self.d/'url.txt').write_text('vless://fixture@host:443?type=tcp#node\n\nvmess://fixture\n')
    def shell(self,body,input=''):
        setup='source "$SCRIPT"\nset -e\nwork_dir="$CASE";config_dir="$CASE/config.json";state_file="$CASE/state.json";client_dir="$CASE/url.txt"\n'
        r=subprocess.run(['bash','-c',setup+body],input=input,text=True,capture_output=True,env={**os.environ,'SCRIPT':str(SCRIPT),'CASE':str(self.d)},timeout=8)
        self.assertEqual(r.returncode,0,r.stderr);return r.stdout+r.stderr
    def test_node_view_has_colors_headings_spacing_and_optional_qr(self):
        out=self.shell('show_nodes\n')
        self.assertIn('\x1b[',out);self.assertIn('=== 当前节点信息 ===',out);self.assertIn('=== 订阅链接 ===',out)
        self.assertIn('http://[2001:db8::1]:18431/fixture-path',out)
        self.assertIn('vless://fixture@host:443?type=tcp#node\x1b[0m\n\n',out)
        qr=self.d/'qrencode';qr.write_text('#!/bin/sh\nprintf QR_EXECUTED\n');qr.chmod(0o700)
        self.assertIn('QR_EXECUTED',self.shell('show_nodes\n'))
    def test_blank_port_retries_reserved_used_and_configured_ports(self):
        self.shell('''
random_port_candidate() { n=$(cat "$CASE/n" 2>/dev/null || echo 0);n=$((n+1));echo "$n" > "$CASE/n";case $n in 1) echo 3001;;2) echo 18431;;3) echo 18433;;4) echo 19000;;*) echo 19001;;esac; }
port_available() { [ "$1" != 19000 ]; }
prompt_port 'RAW端口' 18432
[ "$REPLY" = 19001 ]
''',input='\n')
    def test_port_input_rejects_invalid_then_accepts_original(self):
        self.shell("prompt_port '端口' 18432\n[ \"$REPLY\" = 18432 ]\n",input='70000\n18432\n')
    def test_edge_parser_handles_presets_custom_ipv6_and_keep_current(self):
        self.shell('''
parse_edge_input ''; [ "$EDGE_HOST:$EDGE_PORT" = cdn.example.com:443 ]
parse_edge_input 1; [ "$EDGE_HOST:$EDGE_PORT" = cf.090227.xyz:443 ]
parse_edge_input '[2001:db8::2]:8443';[ "$EDGE_HOST" = 2001:db8::2 ];[ "$EDGE_PORT" = 8443 ]
parse_edge_input example.net:2053;[ "$EDGE_HOST:$EDGE_PORT" = example.net:2053 ]
if parse_edge_input example.net:70000;then exit 1;fi
if parse_edge_input 'https://example.net/path';then exit 1;fi
for bad in '[:::]:443' '[:1::2]:443' '[1::2:]:443' '[1:2:3:4:5:6:7:8:9]:443' '[99999::1]:443' '[::]:443' '999.1.1.1:443';do if parse_edge_input "$bad";then exit 1;fi;done
''')
    def test_edge_menu_changes_both_protocols_through_single_setter(self):
        out=self.shell('set_cdn() { printf "SELECTED=%s:%s\\n" "$1" "$2"; }\ninteractive_cdn\n',input='[2001:db8::3]:8443\n')
        self.assertIn('SELECTED=2001:db8::3:8443',out)
        self.assertNotIn('bestcf.top',out);self.assertNotIn('cfip.xxxxxxxx.tk',out)
    def test_numeric_service_menu_uses_owned_service_only(self):
        out=self.shell('service_action() { printf "ACTION=%s:%s\\n" "$1" "$2"; }\ninteractive_services\n',input='1\n2\n')
        self.assertIn('ACTION=xray2go-core:stop',out)
    def test_invalid_subscription_toggle_is_not_treated_as_disable(self):
        out=self.shell('set_subscription_enabled() { echo UNEXPECTED; }\ninteractive_subscription\n',input='nonsense\n')
        self.assertNotIn('UNEXPECTED',out)
    def test_service_menu_cannot_bypass_disabled_subscription(self):
        s=json.loads((self.d/'state.json').read_text());s['subscription_enabled']=False
        (self.d/'state.json').write_text(json.dumps(s))
        out=self.shell('service_action() { echo UNEXPECTED; }\ninteractive_services\n',input='3\n1\n')
        self.assertNotIn('UNEXPECTED',out)
        self.assertIn('管理订阅',out)

    def test_disabled_subscription_cannot_be_reopened_by_restart(self):
        s=json.loads((self.d/'state.json').read_text());s['subscription_enabled']=False
        (self.d/'state.json').write_text(json.dumps(s))
        out=self.shell('service_action() { echo UNEXPECTED; }\ninteractive_subscription\n',input='4\n')
        self.assertNotIn('UNEXPECTED',out)
        self.assertIn('请先选择开启订阅',out)

    def test_manual_invalid_ipv6_never_changes_saved_address(self):
        out=self.shell('set_server_address() { echo UNEXPECTED; }\nif interactive_address;then exit 1;fi\n',input='3\n:::\n')
        self.assertNotIn('UNEXPECTED',out)
        self.assertIn('IP 格式错误',out)

    def test_numeric_tunnel_menu_handles_quick_switch_without_credentials(self):
        out=self.shell('set_tunnel() { echo "MODE=$1"; }\ninteractive_tunnel\n',input='5\n')
        self.assertIn('MODE=quick',out)
    def test_auto_ip_switch_validates_family_and_rejects_warp(self):
        self.shell('''
curl() { case "${@: -1}" in *trace) printf 'warp=off\\n';;*) echo 203.0.113.2;;esac; }
fetch_direct_ip 4; [ "$REPLY" = 203.0.113.2 ]
curl() { case "${@: -1}" in *trace) printf 'warp=on\\n';;*) echo 203.0.113.2;;esac; }
if fetch_direct_ip 4;then exit 1;fi
''')
    def test_sni_preset_blank_uses_default_and_changes_only_chosen_transport(self):
        out=self.shell('set_sni() { echo "SNI=$1:$2"; }\ninteractive_sni\n',input='2\n\n')
        self.assertIn('SNI=xhttp:www.iij.ad.jp',out)
if __name__=='__main__':unittest.main(verbosity=2)
