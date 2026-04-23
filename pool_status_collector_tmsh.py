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
    output = run_command("tmsh show ltm pool /\*/\* members field-fmt")
    return parse_f5_config(output)


def get_ltm_virtual_stats():
    output = run_command("tmsh show ltm virtual /\*/\* field-fmt")
    return parse_f5_config(output)


def get_gtm_pool_members():
    output = run_command("tmsh show gtm pool a members field-fmt")
    return parse_f5_config(output)


def save_data(data, chassis_id, hostname, date_part, time_part, data_type):
    filename = "/var/tmp/{}__{}__{}__{}__{}.json".format(
        chassis_id, hostname, date_part, time_part, data_type
    )
    with open(filename, 'w') as f:
        json.dump(data, f, indent=2)
    print("Saved to: {}".format(filename))


def display_menu():
    print("\nF5 Data Collection Menu")
    print("-" * 30)
    print("1. LTM Pool Members")
    print("2. LTM Virtual Server Stats")
    print("3. GTM Pool Members")
    print("4. All LTM Data (Pools + Virtuals)")
    print("5. All Data")
    print("6. Exit")
    print("-" * 30)


def get_user_choice():
    while True:
        display_menu()
        choice = input("Enter your choice (1-6): ").strip()
        if choice in ['1', '2', '3', '4', '5', '6']:
            return choice
        print("Invalid choice. Please enter a number between 1 and 6.")


def collect_ltm_pools(chassis_id, hostname, date_part, time_part):
    try:
        ltm_data = get_ltm_pool_members()
        save_data(ltm_data, chassis_id, hostname, date_part, time_part, "ltm_pool_members")
    except Exception as e:
        print("No LTM pools found or error retrieving LTM pool members: {}".format(e))


def collect_ltm_virtuals(chassis_id, hostname, date_part, time_part):
    try:
        virtual_data = get_ltm_virtual_stats()
        save_data(virtual_data, chassis_id, hostname, date_part, time_part, "ltm_virtual_stats")
    except Exception as e:
        print("No LTM virtuals found or error retrieving LTM virtual stats: {}".format(e))


def collect_gtm_pools(chassis_id, hostname, date_part, time_part):
    try:
        gtm_data = get_gtm_pool_members()
        save_data(gtm_data, chassis_id, hostname, date_part, time_part, "gtm_pool_members")
    except Exception as e:
        print("No GTM pools found or error retrieving GTM pool members: {}".format(e))


if __name__ == '__main__':
    choice = get_user_choice()

    if choice == '6':
        print("Exiting.")
        exit(0)

    chassis_id = get_chassis_id()
    hostname = get_hostname()
    now = datetime.now()
    date_part = now.strftime("%Y-%m-%d")
    time_part = now.strftime("%H-%M-%S")

    if choice == '1':
        collect_ltm_pools(chassis_id, hostname, date_part, time_part)
    elif choice == '2':
        collect_ltm_virtuals(chassis_id, hostname, date_part, time_part)
    elif choice == '3':
        collect_gtm_pools(chassis_id, hostname, date_part, time_part)
    elif choice == '4':
        collect_ltm_pools(chassis_id, hostname, date_part, time_part)
        collect_ltm_virtuals(chassis_id, hostname, date_part, time_part)
    elif choice == '5':
        collect_ltm_pools(chassis_id, hostname, date_part, time_part)
        collect_ltm_virtuals(chassis_id, hostname, date_part, time_part)
        collect_gtm_pools(chassis_id, hostname, date_part, time_part)