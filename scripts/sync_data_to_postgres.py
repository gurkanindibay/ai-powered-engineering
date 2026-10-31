#!/usr/bin/env python3
"""Syncs live in-memory SitePulse data (sites, blocks, persons, users, units, dues) directly into PostgreSQL."""

import json
import urllib.request
import subprocess
import sys

CONTAINER = "sitepulse-postgres"
USER = "sitepulse_user"
DB = "sitepulse"

def psql_exec(sql: str):
    cmd = ["docker", "exec", "-i", CONTAINER, "psql", "-U", USER, "-d", DB, "-c", sql]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"SQL Error: {res.stderr}", file=sys.stderr)
        return False
    return True

def main():
    print("Fetching active sites from http://localhost:8080/api/v1/saas/sites...")
    try:
        req = urllib.request.urlopen("http://localhost:8080/api/v1/saas/sites")
        sites = json.loads(req.read().decode('utf-8'))
    except Exception as e:
        print(f"Failed to fetch sites: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(sites)} sites in backend memory.")

    for site in sites:
        site_id_raw = str(site.get('site_id', '1'))
        site_id_num = ''.join(c for c in site_id_raw if c.isdigit()) or '1'
        site_name = site.get('site_name', 'Site').replace("'", "''")
        address = site.get('address', '').replace("'", "''")
        slug = site.get('slug', 'site').replace("'", "''")
        status = site.get('status', 'ACTIVE')
        plan = site.get('plan_type', 'STANDARD')

        print(f"-> Inserting Site {site_name} (ID: {site_id_num})...")
        sql_site = f"""
        INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date)
        VALUES ({site_id_num}, '{site_name}', '{address}', '{slug}', '{status}', '{plan}', CURRENT_DATE + INTERVAL '1 year')
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            address = EXCLUDED.address,
            slug = EXCLUDED.slug,
            status = EXCLUDED.status,
            plan_type = EXCLUDED.plan_type;
        """
        psql_exec(sql_site)

        # Blocks
        blocks = site.get('blocks') or ['A Blok', 'B Blok']
        for idx, bname in enumerate(blocks, start=1):
            clean_bname = bname.replace("'", "''")
            sql_block = f"""
            INSERT INTO blocks (id, site_id, block_name, total_floors)
            VALUES ({idx}, {site_id_num}, '{clean_bname}', 10)
            ON CONFLICT (id) DO UPDATE SET
                site_id = EXCLUDED.site_id,
                block_name = EXCLUDED.block_name;
            """
            psql_exec(sql_block)

        # Manager user
        mgr_name = site.get('primary_manager_name', 'Yonetici').replace("'", "''")
        mgr_email = site.get('primary_manager_email', 'yonetici@site.com').replace("'", "''")
        mgr_phone = site.get('primary_manager_phone', '+90 532 000 0000').replace("'", "''")

        sql_mgr_person = f"""
        INSERT INTO persons (id, full_name, phone, email, person_type)
        VALUES (2, '{mgr_name}', '{mgr_phone}', '{mgr_email}', 'YONETICI')
        ON CONFLICT (id) DO UPDATE SET
            full_name = EXCLUDED.full_name,
            phone = EXCLUDED.phone,
            email = EXCLUDED.email;
        """
        psql_exec(sql_mgr_person)

        sql_mgr_user = f"""
        INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
        VALUES (2, {site_id_num}, '{mgr_name}', '{mgr_email}', '{mgr_phone}', 'ARGON2_HASH_yonetici123', 'SITE_MANAGER', false)
        ON CONFLICT (id) DO UPDATE SET
            site_id = EXCLUDED.site_id,
            full_name = EXCLUDED.full_name,
            email = EXCLUDED.email,
            phone = EXCLUDED.phone;
        """
        psql_exec(sql_mgr_user)

        # Units & residents
        print(f"Fetching home owners for site {site_id_raw}...")
        try:
            req_u = urllib.request.urlopen(f"http://localhost:8080/api/v1/site-admin/home-owners?site_id={site_id_raw}")
            units = json.loads(req_u.read().decode('utf-8'))
        except Exception as e:
            print(f"Could not fetch units: {e}")
            units = []

        print(f"Found {len(units)} units in memory for site.")
        for u in units:
            unit_no = u.get('unit_no', 1)
            unit_id_num = unit_no
            block_str = u.get('block', 'A Blok')
            block_id_num = 2 if 'B' in block_str else 1
            floor = u.get('floor', 1)
            owner_name = u.get('owner_full_name', f'Daire {unit_no} Sakini').replace("'", "''")
            email = u.get('email', f'daire{unit_no}@test.com').replace("'", "''")
            phone = u.get('phone', '+90 532 555 0000').replace("'", "''")
            person_id = 100 + unit_no
            viban = u.get('virtual_iban', f'TR91002050000986379160{unit_no:04d}')

            # Person
            sql_p = f"""
            INSERT INTO persons (id, full_name, phone, email, person_type)
            VALUES ({person_id}, '{owner_name}', '{phone}', '{email}', 'KAT_MALIKI')
            ON CONFLICT (id) DO UPDATE SET
                full_name = EXCLUDED.full_name,
                phone = EXCLUDED.phone,
                email = EXCLUDED.email;
            """
            psql_exec(sql_p)

            # User
            sql_u = f"""
            INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
            VALUES ({person_id}, {site_id_num}, '{owner_name}', '{email}', '{phone}', 'ARGON2_HASH_123456', 'HOME_OWNER', false)
            ON CONFLICT (id) DO UPDATE SET
                site_id = EXCLUDED.site_id,
                full_name = EXCLUDED.full_name,
                email = EXCLUDED.email;
            """
            psql_exec(sql_u)

            # Unit
            sql_unit = f"""
            INSERT INTO units (id, block_id, site_id, unit_number, floor, land_share, owner_person_id, virtual_iban)
            VALUES ({unit_id_num}, {block_id_num}, {site_id_num}, {unit_no}, {floor}, 24, {person_id}, '{viban}')
            ON CONFLICT (id) DO UPDATE SET
                block_id = EXCLUDED.block_id,
                site_id = EXCLUDED.site_id,
                unit_number = EXCLUDED.unit_number,
                floor = EXCLUDED.floor,
                owner_person_id = EXCLUDED.owner_person_id,
                virtual_iban = EXCLUDED.virtual_iban;
            """
            psql_exec(sql_unit)

            # Dues
            sql_due = f"""
            INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, due_date, status, delay_penalty)
            VALUES ({1000 + unit_no}, {unit_id_num}, 'Ekim 2026', 1400.00, CURRENT_DATE + INTERVAL '15 days', 'PENDING', 0.00)
            ON CONFLICT (id) DO NOTHING;
            """
            psql_exec(sql_due)

    print("Sync complete!")

if __name__ == '__main__':
    main()

