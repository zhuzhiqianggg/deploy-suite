# POC 环境信息

## POC内网服务器器
服务器：173.23.1.2 ｜ 命名空间：db-lianantech-hk-release
集群内访问格式：{服务名}.db-lianantech-hk-release.svc.cluster.local

## 接入方式（VPN / SSH）

- VPN：连接方式见《环境使用指导书.pdf》
  - 地址：123.60.230.181:41024 或 121.37.53.148:41024
  - 账号：lab_s1t1zg | 9DmCEk9TFK
- 服务器：173.23.1.2:22（连接 VPN 后访问），SSH 账号：ubuntu | beosin@123

## 数据传输服务器（华为云国内）

- 公网地址：60.204.235.167
  内网地址：192.168.1.68
  SSH账号：root | beosin@123


## Kuboard

- 地址：http://173.23.1.2:30080
- 账号：admin | Beosin@123

## minio
外部访问地址： http://173.23.1.2:30309/buckets
集群内部访问： minio-service.db-lianantech-hk-release.svc.cluster.local
账号：
root_user: minio-root
root_password: Tn5vBq8wXz2Lm6Kd


## MySQL

- 地址：mysql-service:3306
- 账号：root | zTcKwbKCCRyqAg3vlU2g
- 业务账号：api_user | OMPwPU34OLSXSVI4（api 库）、kya_user | B8YYfeJi35rdVUdm（kya 库）、kyt_user | Na7MALN6zNUeQbMA（kyt 库），其余库用 root

## Redis

- 地址：redis-service:6379
- 密码：#B7PTagA1B6#*pL@rwJ#（无账号）

## Kafka

- 地址：kafka-service:9092（对外 173.23.1.2:31775）
- 账号：无（PLAINTEXT）

## Kafka UI

- 地址：kafka-ui-service:8080（对外 173.23.1.2:31192，无认证）

## Elasticsearch

- 地址：elasticsearch-service:9200（对外 173.23.1.2:30464）
- 账号：elastic | S0CDdiK2lIYixrrAUH7C

## Kibana

- 地址：kibana-service:5601（对外 173.23.1.2:32357）
- 账号：elastic | S0CDdiK2lIYixrrAUH7C

## Doris

- 地址：173.23.1.2:9030
- 账号：root | 0Bazk1ZmhDkSVCiG7IVv

## NebulaGraph

- 地址：nebula-service:9669（对外 173.23.1.2:30669）
- 账号：root | R7xJc3IngwyAaMG1XDv3
- Studio：http://173.23.1.2:30800（账号 root | nebula）

## 内存分配（1TiB）

| 组件 | 限额 |
|---|---|
| Elasticsearch | 64G × 3 = 192G |
| NebulaGraph | 122G（单机：storaged 100G + graphd 16G + metad 6G） |
| Doris | 200G（BE 184G + FE 16G；BE 围栏 170G/184G，be.conf mem_limit=170G） |
| 应用 / MySQL / Redis 等 | 470G |
| 系统与页缓存 | ~20G |

物理内存实测 1005G，限额合计 1004G，无 swap；各组件限额总和不得超物理内存。

