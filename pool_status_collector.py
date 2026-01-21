import subprocess
import re
import json
from datetime import datetime


def parse_f5_config(text):
    def parse_block(lines, idx=0):
        result = {}
        while idx < len(lines):
            line = lines[idx].strip()
            if not line or line == '}':
                return result, idx

            if '{' in line:
                key = line.replace('{', '').strip()
                nested, idx = parse_block(lines, idx + 1)
                if key in result:
                    if not isinstance(result[key], list):
                        result[key] = [result[key]]
                    result[key].append(nested)
                else:
                    result[key] = nested
            else:
                match = re.match(r'^([\w\-.]+)\s+(.*)$', line)
                if match:
                    key, value = match.groups()
                    try:
                        value = int(value)
                    except ValueError:
                        try:
                            value = float(value)
                        except ValueError:
                            pass
                    result[key] = value
            idx += 1
        return result, idx

    lines = text.strip().split('\n')
    result, _ = parse_block(lines)
    return result


def run_command(cmd):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    stdout, stderr = proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError("Command failed: {}".format(stderr.decode()))
    return stdout.decode()


def get_chassis_id():
    output = run_command("tmsh show sys hardware field-fmt | grep bigip-chassis-serial-num")
    return output.strip().split()[-1]


def get_hostname():
    output = run_command("tmsh list sys global-settings hostname | grep hostname")
    return output.strip().split()[-1]


def get_ltm_pool_members():
    output = run_command("tmsh show ltm pool members field-fmt")
    return parse_f5_config(output)


def get_gtm_pool_members():
    output = run_command("tmsh show gtm pool a members field-fmt")
    return parse_f5_config(output)


def save_pool_data(data, chassis_id, hostname, date_part, time_part, pool_type):
    filename = "/var/tmp/{}__{}__{}__{}__{}_pool_members.json".format(
        chassis_id, hostname, date_part, time_part, pool_type
    )
    with open(filename, 'w') as f:
        json.dump(data, f, indent=2)
    print("Saved to: {}".format(filename))


if __name__ == '__main__':
    chassis_id = get_chassis_id()
    hostname = get_hostname()
    now = datetime.now()
    date_part = now.strftime("%Y-%m-%d")
    time_part = now.strftime("%H-%M-%S")

    try:
        ltm_data = get_ltm_pool_members()
        save_pool_data(ltm_data, chassis_id, hostname, date_part, time_part, "ltm")
    except:
        print("No LTM pools found or error retrieving LTM pool members.")

    try:
        gtm_data = get_gtm_pool_members()
        save_pool_data(gtm_data, chassis_id, hostname, date_part, time_part, "gtm")
    except:
        print("No GTM pools found or error retrieving GTM pool members.")