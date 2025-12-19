#!/usr/bin/env python3
"""
사용자 정보를 MySQL 데이터베이스에서 추출하여 Excel 파일로 저장하는 스크립트

출력 디렉토리: ../excel_exports/
출력 파일: user_export_YYYY-MM-DD.xlsx
"""

import pymysql
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill
from datetime import datetime
import sys
import os

# Google Sheets API
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# 데이터베이스 연결 정보
def load_db_config():
    """db_config.env 파일에서 데이터베이스 설정을 읽어옵니다."""
    config = {}
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_file = os.path.join(script_dir, 'db_config.env')

    with open(config_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                if '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip()

    return {
        'host': config['DB_HOST'],
        'port': int(config['DB_PORT']),
        'user': config['DB_USER'],
        'password': config['DB_PASSWORD'],
        'database': config['DB_NAME'],
        'charset': config['DB_CHARSET']
    }

DB_CONFIG = load_db_config()

# Google Sheets 설정
SPREADSHEET_ID = '1U3-YidZrxNHH4mEbq6-MaxZqsUWJ6HZn2GV9flwIwPY'
SCOPES = ['https://www.googleapis.com/auth/spreadsheets']

def get_user_data():
    """데이터베이스에서 사용자 정보를 조회"""
    try:
        connection = pymysql.connect(**DB_CONFIG)
        cursor = connection.cursor()

        # 사용자 정보 조회 쿼리
        query = """
        SELECT
            '' AS '존재여부',
            u.name AS '이름',
            u.ubuntu_username AS '로그인 아이디',
            g.ubuntu_groupname AS '그룹명',
            dc.server_id AS '배정 서버',
            u.ubuntu_uid AS 'UID',
            u.ubuntu_gid AS 'GID',
            GROUP_CONCAT(DISTINCT up.port_number ORDER BY up.port_number SEPARATOR ', ') AS '포트 번호',
            DATE_FORMAT(dc.expiring_at, '%Y-%m-%d') AS '서버 사용 완료 예정일',
            DATE_FORMAT(DATE_ADD(dc.expiring_at, INTERVAL 15 DAY), '%Y-%m-%d') AS '스토리지 삭제 예정일',
            dc.created_by AS '컨테이너 생성자',
            DATE_FORMAT(dc.created_at, '%Y-%m-%d') AS '컨테이너 생성일자',
            CONCAT(dc.image, ':', dc.image_version) AS 'docker image version',
            dc.container_name AS '컨테이너 명',
            '' AS 'E-mail',
            '' AS '전화번호',
            '' AS '사용여부',
            u.note AS '비고'
        FROM user u
        LEFT JOIN `group` g ON u.ubuntu_gid = g.ubuntu_gid
        LEFT JOIN docker_container dc ON u.id = dc.user_id
        LEFT JOIN used_ports up ON dc.id = up.docker_container_record_id
        GROUP BY u.id, dc.id
        ORDER BY dc.server_id ASC, u.name ASC;
        """

        cursor.execute(query)
        columns = [desc[0] for desc in cursor.description]
        rows = cursor.fetchall()

        cursor.close()
        connection.close()

        return columns, rows

    except pymysql.Error as e:
        print(f"데이터베이스 오류: {e}")
        sys.exit(1)

def create_excel(columns, data, filename):
    """엑셀 파일 생성"""
    wb = Workbook()
    ws = wb.active
    ws.title = "사용자 정보"

    # 헤더 스타일 설정
    header_font = Font(bold=True, color="FFFFFF")
    header_fill = PatternFill(start_color="4472C4", end_color="4472C4", fill_type="solid")
    header_alignment = Alignment(horizontal="center", vertical="center")

    # 헤더 작성
    for col_idx, column_name in enumerate(columns, start=1):
        cell = ws.cell(row=1, column=col_idx)
        cell.value = column_name
        cell.font = header_font
        cell.fill = header_fill
        cell.alignment = header_alignment

    # 데이터 작성
    for row_idx, row_data in enumerate(data, start=2):
        for col_idx, value in enumerate(row_data, start=1):
            cell = ws.cell(row=row_idx, column=col_idx)
            cell.value = value
            cell.alignment = Alignment(vertical="center")

    # 컬럼 너비 자동 조정
    for column in ws.columns:
        max_length = 0
        column_letter = column[0].column_letter

        for cell in column:
            try:
                if cell.value:
                    max_length = max(max_length, len(str(cell.value)))
            except:
                pass

        adjusted_width = min(max_length + 2, 50)  # 최대 50으로 제한
        ws.column_dimensions[column_letter].width = adjusted_width

    # 파일 저장
    try:
        wb.save(filename)
        print(f"✓ 엑셀 파일이 성공적으로 생성되었습니다: {filename}")
        print(f"✓ 총 {len(data)}개의 레코드가 저장되었습니다.")
    except Exception as e:
        print(f"파일 저장 오류: {e}")
        sys.exit(1)

def get_google_sheets_service(credentials_path):
    """Google Sheets API 서비스 객체 생성"""
    try:
        credentials = service_account.Credentials.from_service_account_file(
            credentials_path, scopes=SCOPES)
        service = build('sheets', 'v4', credentials=credentials)
        return service
    except Exception as e:
        print(f"Google Sheets 인증 오류: {e}")
        return None

def ensure_sheet_exists(service, sheet_name):
    """시트가 존재하는지 확인하고, 없으면 생성"""
    try:
        spreadsheet = service.spreadsheets().get(spreadsheetId=SPREADSHEET_ID).execute()
        sheets = spreadsheet.get('sheets', [])

        # 시트가 이미 존재하는지 확인
        for sheet in sheets:
            if sheet['properties']['title'] == sheet_name:
                print(f"✓ '{sheet_name}' 시트가 이미 존재합니다.")
                return sheet['properties']['sheetId']

        # 시트가 없으면 새로 생성
        print(f"'{sheet_name}' 시트를 생성합니다...")
        requests = [{
            'addSheet': {
                'properties': {
                    'title': sheet_name
                }
            }
        }]

        response = service.spreadsheets().batchUpdate(
            spreadsheetId=SPREADSHEET_ID,
            body={'requests': requests}
        ).execute()

        sheet_id = response['replies'][0]['addSheet']['properties']['sheetId']
        print(f"✓ '{sheet_name}' 시트가 생성되었습니다.")
        return sheet_id

    except HttpError as e:
        print(f"시트 확인/생성 오류: {e}")
        return None

def update_google_sheet(service, columns, data, sheet_name='LAB'):
    """Google Sheets에 데이터 업데이트"""
    try:
        # 시트가 존재하는지 확인하고, 없으면 생성
        sheet_id = ensure_sheet_exists(service, sheet_name)
        if sheet_id is None:
            return False

        # 데이터 준비 (헤더 + 데이터 행)
        values = [list(columns)]  # 헤더 행
        for row in data:
            # None 값을 빈 문자열로 변환
            cleaned_row = ['' if v is None else str(v) for v in row]
            values.append(cleaned_row)

        # 시트 범위 계산 (LAB 시트의 A1부터 시작)
        sheet_range = f'{sheet_name}!A1'

        # 기존 데이터 삭제
        service.spreadsheets().values().clear(
            spreadsheetId=SPREADSHEET_ID,
            range=f'{sheet_name}!A:Z'
        ).execute()

        # 새 데이터 업데이트
        body = {
            'values': values
        }

        result = service.spreadsheets().values().update(
            spreadsheetId=SPREADSHEET_ID,
            range=sheet_range,
            valueInputOption='RAW',
            body=body
        ).execute()

        # 헤더 서식 적용 (배경색, 볼드)
        format_header(service, len(columns), sheet_id)

        updated_cells = result.get('updatedCells', 0)
        print(f"✓ Google Sheets '{sheet_name}' 시트 업데이트 완료: {updated_cells}개의 셀이 업데이트되었습니다.")
        return True

    except HttpError as e:
        print(f"Google Sheets API 오류: {e}")
        return False
    except Exception as e:
        print(f"Google Sheets 업데이트 오류: {e}")
        return False

def format_header(service, num_columns, sheet_id):
    """Google Sheets 헤더에 서식 적용 (배경색, 볼드)"""
    try:
        requests = [
            {
                'repeatCell': {
                    'range': {
                        'sheetId': sheet_id,
                        'startRowIndex': 0,
                        'endRowIndex': 1,
                        'startColumnIndex': 0,
                        'endColumnIndex': num_columns
                    },
                    'cell': {
                        'userEnteredFormat': {
                            'backgroundColor': {
                                'red': 0.267,
                                'green': 0.447,
                                'blue': 0.769
                            },
                            'textFormat': {
                                'bold': True,
                                'foregroundColor': {
                                    'red': 1.0,
                                    'green': 1.0,
                                    'blue': 1.0
                                }
                            },
                            'horizontalAlignment': 'CENTER',
                            'verticalAlignment': 'MIDDLE'
                        }
                    },
                    'fields': 'userEnteredFormat(backgroundColor,textFormat,horizontalAlignment,verticalAlignment)'
                }
            }
        ]

        service.spreadsheets().batchUpdate(
            spreadsheetId=SPREADSHEET_ID,
            body={'requests': requests}
        ).execute()

        print(f"✓ Google Sheets 헤더 서식 적용 완료")

    except HttpError as e:
        print(f"헤더 서식 적용 오류: {e}")

def main():
    """메인 함수"""
    print("=" * 60)
    print("사용자 정보 엑셀 추출 스크립트")
    print("=" * 60)

    # 스크립트의 상위 디렉토리 경로 (UID-GID-Management-System)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)

    # 엑셀 데이터 저장 디렉토리 생성
    export_dir = os.path.join(project_root, "excel_exports")
    os.makedirs(export_dir, exist_ok=True)

    # 현재 날짜로 파일명 생성
    today = datetime.now().strftime("%Y-%m-%d")
    filename = os.path.join(export_dir, f"user_export_{today}.xlsx")

    print(f"\n저장 디렉토리: {export_dir}")
    print(f"데이터베이스 연결 중... ({DB_CONFIG['host']}:{DB_CONFIG['port']})")

    # 데이터 조회
    columns, data = get_user_data()
    print(f"✓ 데이터 조회 완료: {len(data)}개의 레코드")

    # 엑셀 파일 생성
    print(f"\n엑셀 파일 생성 중: {os.path.basename(filename)}")
    create_excel(columns, data, filename)

    # Google Sheets 업데이트
    print(f"\nGoogle Sheets 업데이트 중...")
    credentials_path = os.path.join(project_root, "user-management-478704-d311d4ce0dc3.json")

    if os.path.exists(credentials_path):
        service = get_google_sheets_service(credentials_path)
        if service:
            update_google_sheet(service, columns, data)
        else:
            print("⚠ Google Sheets 서비스 연결 실패")
    else:
        print(f"⚠ 인증 파일을 찾을 수 없습니다: {credentials_path}")

    print("\n" + "=" * 60)
    print("작업 완료!")
    print("=" * 60)

if __name__ == "__main__":
    main()
