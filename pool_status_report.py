import json
import pandas as pd


def compare_pool_states(file1_path, file2_path, output_path):
    # Load JSON files
    with open(file1_path, 'r') as f:
        data1 = json.load(f)

    with open(file2_path, 'r') as f:
        data2 = json.load(f)

    results = []

    # Get all pool names from both files
    all_pools = set(data1.keys()) | set(data2.keys())

    for pool_name in sorted(all_pools):
        # Compare pool level
        pool1_state = data1.get(pool_name, {}).get('status.availability-state', 'N/A')
        pool2_state = data2.get(pool_name, {}).get('status.availability-state', 'N/A')

        results.append({
            'Type': 'Pool',
            'Name': pool_name,
            'File 1 State': pool1_state,
            'File 2 State': pool2_state,
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
                'File 1 State': member1_state,
                'File 2 State': member2_state,
                'Match': 'Yes' if member1_state == member2_state else 'No'
            })

    # Create DataFrame and save to Excel
    df = pd.DataFrame(results)
    df.to_excel(output_path, index=False)
    print(f"Comparison saved to {output_path}")


if __name__ == "__main__":
    compare_pool_states('c1ae2eec-66f5-87c0-138b45053ffb_20251127_134800_pool_members.json',
                        'c1ae2eec-66f5-87c0-138b45053ffb_20251127_162737_pool_members.json',
                        'pool_comparison.xlsx')