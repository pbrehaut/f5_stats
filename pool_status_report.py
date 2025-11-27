import json
import pandas as pd
import os
from datetime import datetime

# Mapping of host IDs to alternate hostnames
HOST_MAPPING = {
    'c1ae2eec-66f5-87c0-138b45053ffb': 'F51',
    'host2': 'F52'
}


def extract_file_info(filepath):
    """Extract host ID and timestamp from filename"""
    filename = os.path.basename(filepath)
    filename_without_ext = filename.replace('.json', '')

    # Expected format: hostID__YYYY-MM-DD__HH-MM-SS
    parts = filename_without_ext.split('__')

    if len(parts) >= 3:
        host_id = parts[0]
        date_str = parts[1]
        time_str = parts[2]

        # Map host ID to alternate hostname
        alt_hostname = HOST_MAPPING.get(host_id, host_id)

        # Parse datetime using datetime module
        datetime_str = f"{date_str} {time_str.replace('-', ':')}"
        try:
            dt = datetime.strptime(datetime_str, '%Y-%m-%d %H:%M:%S')
            formatted_datetime = dt.strftime('%Y-%m-%d %H:%M:%S')
            return alt_hostname, formatted_datetime
        except ValueError:
            return alt_hostname, datetime_str
    else:
        return 'Unknown', 'Unknown'


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
    print(f"Comparison saved to {output_path}")
    print(f"Compared {host1} ({time1}) vs {host2} ({time2})")


if __name__ == "__main__":
    compare_pool_states('c1ae2eec-66f5-87c0-138b45053ffb__2025-11-27__17-30-25_pool_members.json',
                        'c1ae2eec-66f5-87c0-138b45053ffb__2025-11-27__17-30-39_pool_members.json',
                        'pool_comparison.xlsx')