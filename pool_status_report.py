import json
import pandas as pd
import os

# Mapping of host IDs to sites
CHASSIS_MAPPING = {
    'c1ae2eec-66f5-87c0-138b45053ffb': 'HMB-Viprion',
    'c1ae2eec-66f5-87c0-138b45053ffb-2': 'HMB-R5900',
}


def extract_file_info(filepath):
    """Extract host ID and timestamp from filename"""
    filename = os.path.basename(filepath)
    filename_without_ext = filename.replace('.json', '')

    # Expected format: hostID__YYYY-MM-DD__HH-MM-SS
    parts = filename_without_ext.split('__')

    site_id = parts[0]
    host_name = parts[1]
    date_str = parts[2]
    time_str = parts[3]

    # Map host ID to alternate hostname
    alt_site_name = CHASSIS_MAPPING.get(site_id, site_id)

    # Parse datetime using datetime module
    datetime_str = f"{date_str} {time_str.replace('-', ':')}"
    return alt_site_name + ' ' + host_name, datetime_str


def get_available_files():
    """Scan current directory for pool_members.json files"""
    files = [f for f in os.listdir('.') if f.endswith('__pool_members.json')]
    return sorted(files)


def display_menu(files):
    """Display menu with mapped site names"""
    print("\nAvailable files:")
    print("-" * 80)
    for idx, filepath in enumerate(files, 1):
        site_name, timestamp = extract_file_info(filepath)
        print(f"{idx}. {site_name} - {timestamp}")
    print("-" * 80)


def select_files():
    """Allow user to select exactly 2 files"""
    files = get_available_files()

    if len(files) < 2:
        print("Error: At least 2 files are required for comparison.")
        return None, None

    display_menu(files)

    selected_files = []

    while len(selected_files) < 2:
        try:
            choice = input(f"\nSelect file {len(selected_files) + 1} (enter number): ").strip()
            idx = int(choice) - 1

            if idx < 0 or idx >= len(files):
                print("Invalid selection. Please try again.")
                continue

            if files[idx] in selected_files:
                print("File already selected. Please choose a different file.")
                continue

            selected_files.append(files[idx])

        except ValueError:
            print("Please enter a valid number.")
        except KeyboardInterrupt:
            print("\nOperation cancelled.")
            return None, None

    return selected_files[0], selected_files[1]


def compare_pool_states(file1_path, file2_path, output_path):
    # Extract file information
    host1, time1 = extract_file_info(file1_path)
    host2, time2 = extract_file_info(file2_path)

    # Load JSON files
    with open(file1_path, 'r') as f:
        data1 = json.load(f)

    with open(file2_path, 'r') as f:
        data2 = json.load(f)

    results = []

    # Column headers with host and time information
    col1_header = f"{host1} ({time1})"
    col2_header = f"{host2} ({time2})"

    # Get all pool names from both files
    all_pools = set(data1.keys()) | set(data2.keys())

    for pool_name in sorted(all_pools):
        # Compare pool level
        pool1_state = data1.get(pool_name, {}).get('status.availability-state', 'N/A')
        pool2_state = data2.get(pool_name, {}).get('status.availability-state', 'N/A')

        results.append({
            'Type': 'Pool',
            'Name': pool_name,
            col1_header: pool1_state,
            col2_header: pool2_state,
            'Match': 'Yes' if pool1_state == pool2_state else 'No'
        })

        # Get all members from both files for this pool
        members1 = data1.get(pool_name, {}).get('members', {})
        members2 = data2.get(pool_name, {}).get('members', {})
        all_members = set(members1.keys()) | set(members2.keys())

        # Compare members
        for member_name in sorted(all_members):
            member1_state = members1.get(member_name, {}).get('status.availability-state', 'N/A')
            member2_state = members2.get(member_name, {}).get('status.availability-state', 'N/A')

            results.append({
                'Type': 'Member',
                'Name': f"{pool_name} -> {member_name}",
                col1_header: member1_state,
                col2_header: member2_state,
                'Match': 'Yes' if member1_state == member2_state else 'No'
            })

    # Create DataFrame and save to Excel
    df = pd.DataFrame(results)
    df.to_excel(output_path, index=False)
    print(f"\nComparison saved to {output_path}")
    print(f"Compared {host1} ({time1}) vs {host2} ({time2})")


if __name__ == "__main__":
    file1, file2 = select_files()

    if file1 and file2:
        compare_pool_states(file1, file2, 'pool_comparison.xlsx')