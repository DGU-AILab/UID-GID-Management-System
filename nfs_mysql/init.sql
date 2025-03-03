-- Create the database with explicit character set
CREATE DATABASE IF NOT EXISTS nfs_db CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

USE nfs_db;

-- Create used_ids table for ID management
CREATE TABLE
    used_ids (id INT PRIMARY KEY AUTO_INCREMENT) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Create group table
CREATE TABLE
    `group` (
        id INT PRIMARY KEY AUTO_INCREMENT,
        ubuntu_groupname VARCHAR(255) NOT NULL,
        ubuntu_gid INT NOT NULL,
        UNIQUE KEY unique_gid (ubuntu_gid),
        FOREIGN KEY (ubuntu_gid) REFERENCES used_ids (id)
    ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Create user table without circular references
CREATE TABLE
    user(
        id INT PRIMARY KEY AUTO_INCREMENT,
        name VARCHAR(255) NOT NULL,
        ubuntu_username VARCHAR(255) NOT NULL,
        ubuntu_uid INT NOT NULL,
        ubuntu_gid INT,
        note TEXT,
        UNIQUE KEY unique_uid (ubuntu_uid),
        FOREIGN KEY (ubuntu_uid) REFERENCES used_ids (id),
        FOREIGN KEY (ubuntu_gid) REFERENCES `group` (ubuntu_gid)
    ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Create docker_container table
CREATE TABLE
    docker_container (
        id INT PRIMARY KEY AUTO_INCREMENT,
        image VARCHAR(255) NOT NULL,
        image_version VARCHAR(50) NOT NULL,
        container_id VARCHAR(64) NOT NULL,
        container_name VARCHAR(255) NOT NULL,
        server_id VARCHAR(255) NOT NULL,
        expiring_at DATETIME NOT NULL,
        deleted_at DATETIME,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        existing BOOLEAN DEFAULT TRUE,
        created_by VARCHAR(255),
        user_id INT,
        UNIQUE KEY unique_container (container_id),
        FOREIGN KEY (user_id) REFERENCES user(id)
    ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Create used_ports table after docker_container exists
CREATE TABLE
    used_ports (
        port_number INT PRIMARY KEY,
        docker_container_record_id INT,
        purpose_of_use VARCHAR(255),
        FOREIGN KEY (docker_container_record_id) REFERENCES docker_container (id)
    ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Add indexes
CREATE INDEX idx_container_existing ON docker_container (existing);

CREATE INDEX idx_container_expiring ON docker_container (expiring_at);

CREATE INDEX idx_user_username ON user(ubuntu_username);

-- Verify character set settings
SET NAMES utf8mb4;

CREATE VIEW
    user_container_info AS
SELECT
    u.name AS '사용자 이름',
    u.ubuntu_username AS '우분투 아이디',
    g.ubuntu_groupname AS '우분투 그룹 이름',
    dc.server_id AS '배정된 서버',
    (
        SELECT
            up.port_number
        FROM
            used_ports up
        WHERE
            up.docker_container_record_id = dc.id
            AND up.purpose_of_use = 'ssh'
    ) AS 'ssh 포트',
    (
        SELECT
            up.port_number
        FROM
            used_ports up
        WHERE
            up.docker_container_record_id = dc.id
            AND up.purpose_of_use = 'jupyter notebook'
    ) AS 'jupyter 포트',
    (
        SELECT
            GROUP_CONCAT(
                up.port_number
                ORDER BY
                    up.port_number SEPARATOR ', '
            )
        FROM
            used_ports up
        WHERE
            up.docker_container_record_id = dc.id
            AND up.purpose_of_use != 'ssh'
            AND up.purpose_of_use != 'jupyter notebook'
    ) AS '기타 할당 포트',
    dc.expiring_at AS '사용 만료일',
    dc.created_by AS '컨테이너 생성한 관리자',
    dc.created_at AS '컨테이너 생성 일자',
    dc.image AS '컨테이너 이미지',
    dc.image_version AS '컨테이너 버전',
    dc.container_name AS '컨테이너 이름',
    u.note AS '노트'
FROM
    user u
    LEFT JOIN `group` g ON u.ubuntu_gid = g.ubuntu_gid
    JOIN docker_container dc ON u.id = dc.user_id
WHERE
    dc.existing = TRUE
ORDER BY
    dc.server_id ASC,
    u.name ASC;