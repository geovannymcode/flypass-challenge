# Procesamiento Batch Asíncrono y Gestión de Cambios con Liquibase

## Estructura del Proyecto

```
liquibase-flypass/
├── db.changelog-master.xml
├── changelogs/
│   ├── 01-schema.xml
│   └── 02-packages.xml
├── sql/
│   ├── 01a-clean-sequences.sql
│   ├── 01b-clean-queues.sql
│   ├── 01c-clean-tables.sql
│   ├── 02-create-tables.sql
│   ├── 03-create-sequences.sql
│   ├── 04-create-types.sql
│   ├── 05-create-aq.sql
│   ├── 06-insert-test-data.sql
│   ├── 07-pkg-procesos-spec.sql
│   ├── 08-pkg-procesos-body.sql
│   ├── 09-pkg-notificaciones-spec.sql
│   ├── 10-pkg-notificaciones-body.sql
│   └── 11-create-indexes.sql
├── docker/
│   ├── docker-compose.yml
│   └── ojdbc8.jar
└── README.md
```

## Decisiones de Diseño

### Arquitectura de Procesamiento Batch

La solución implementa un procesamiento por lotes eficiente que:

- **Procesa transacciones en lotes configurables** (BATCH_SIZE = 500) para optimizar el rendimiento sin saturar la memoria
- **Utiliza BULK COLLECT con LIMIT** para controlar el consumo de memoria durante la carga de datos
- **Implementa FORALL** para operaciones DML masivas, reduciendo significativamente el context switching
- **Aplica política de COMMIT por lote** para garantizar la durabilidad de las transacciones sin sacrificar rendimiento
- **Proporciona manejo de errores a nivel de fila** mediante SAVE EXCEPTIONS, evitando que un error en un registro detenga todo el procesamiento

### Control de Concurrencia

Se implementó un mecanismo robusto para evitar que múltiples ejecuciones simultáneas procesen los mismos registros:

- **Marcado atómico de registros** con ID_LOTE_PROCESO único antes del procesamiento
- **Estado "PROCESANDO"** para indicar registros en curso
- **Liberación de registros bloqueados** en caso de errores para evitar bloqueos permanentes

### Notificaciones Asíncronas

El sistema de notificaciones está completamente desacoplado del flujo principal:

- **Uso de Oracle Advanced Queuing (AQ)** para encolar mensajes sin bloquear el proceso principal
- **Implementación de un consumidor independiente** (PKG_NOTIFICACIONES_CONSUMER)
- **Procesamiento asíncrono** garantizando que fallos en notificaciones no afecten transacciones principales

## Estrategia de Optimización y Justificación de Índices

### Índices Implementados

1. **IDX_PASOS_PENDIENTES_ESTADO**: Índice compuesto sobre ESTADO e ID_LOTE_PROCESO
   - Optimiza la selección de registros pendientes, la operación más frecuente del sistema
   - Reduce significativamente el tiempo de selección de lotes para procesamiento

2. **IDX_PASOS_TAG**: Índice sobre ID_TAG
   - Acelera la búsqueda de transacciones por tag, especialmente importante en validaciones

3. **IDX_PASOS_PEAJE**: Índice sobre ID_PEAJE
   - Mejora consultas por peaje para informes y análisis

4. **IDX_VEHICULOS_TAG_ESTADO**: Índice sobre ESTADO
   - Optimiza la validación de estado de tags (activo, robado, inactivo)

5. **IDX_MEMBRESIAS_CLIENTE_ACTIVAS**: Índice compuesto sobre ID_CLIENTE, ID_MEMBRESIA, FECHA_INICIO, FECHA_FIN
   - Crucial para determinar rápidamente si un cliente tiene membresía activa
   - Evita full table scans en una operación crítica del flujo de negocio

6. **IDX_TRANSACCIONES_CLIENTE** e **IDX_TRANSACCIONES_PASO**:
   - Optimizan consultas de auditoría y reportes históricos

### Técnicas de Optimización Adicionales

- Arrays PL/SQL para minimizar context switching
- Procesamiento por lotes con límites configurables
- Evitar recursión y loops anidados innecesarios
- Uso extensivo de operaciones masivas (BULK COLLECT, FORALL)

## Razones para Usar una Arquitectura de Colas (AQ)

### 1. Desacoplamiento
- Las notificaciones se generan sin bloquear el flujo principal de procesamiento
- El éxito o fallo del envío de notificaciones no afecta la integridad de las transacciones

### 2. Escalabilidad
- El consumidor de notificaciones puede escalar independientemente del procesador principal
- Se pueden agregar múltiples consumidores para distribuir la carga

### 3. Persistencia y Fiabilidad
- Las notificaciones quedan garantizadas incluso ante caídas del sistema
- Oracle AQ ofrece persistencia, evitando pérdida de mensajes

### 4. Transaccionalidad
- El encolamiento forma parte de la misma transacción que el procesamiento
- Si la transacción falla, el mensaje no se encola, garantizando consistencia

### 5. Control de Recursos
- Evita picos de consumo en sistemas externos (SMS, email)
- Permite implementar rate limiting sin afectar el proceso principal

## Configuración con Docker

### Requisitos Previos
- Docker y Docker Compose instalados
- Acceso a internet para descargar imágenes

### Configuración del Entorno Docker

1. **Crear archivo `docker-compose.yml` en la carpeta `docker/`:**

```yaml
version: '3'

services:
  oracle:
    image: gvenzl/oracle-xe:21-slim
    container_name: oracle-xe
    environment:
      - ORACLE_PASSWORD=oracle
      - APP_USER=flypass
      - APP_USER_PASSWORD=flypass
    ports:
      - "1521:1521"
    volumes:
      - oracle-data:/opt/oracle/oradata
    healthcheck:
      test: ["CMD", "sqlplus", "-L", "sys/oracle@//localhost:1521/XEPDB1 as sysdba", "@healthcheck.sql"]
      interval: 30s
      timeout: 10s
      retries: 5

  liquibase:
    image: liquibase/liquibase:4.20
    depends_on:
      - oracle
    volumes:
      - ../liquibase-flypass:/liquibase/workspace
      - ./ojdbc8.jar:/liquibase/lib/ojdbc8.jar
    working_dir: /liquibase/workspace
    command: >
      --defaults-file=liquibase.properties update

volumes:
  oracle-data:
```

2. **Descargar el driver JDBC de Oracle** (ojdbc8.jar) desde Oracle JDBC Downloads y colocarlo en la carpeta `docker/`

3. **Iniciar el entorno:**

```bash
# Navega a la carpeta docker
cd docker

# Inicia Oracle
docker-compose up -d oracle

# Espera a que Oracle esté completamente iniciado (unos minutos)
# Ejecuta Liquibase para aplicar los cambios
docker-compose up liquibase
```

4. **Otorgar privilegios para AQ (Oracle Advanced Queuing):**

Conéctate como usuario SYS y ejecuta:

```sql
GRANT EXECUTE ON DBMS_AQADM TO flypass;
GRANT AQ_ADMINISTRATOR_ROLE TO flypass;
GRANT EXECUTE ON DBMS_AQ TO flypass;
GRANT CREATE TYPE TO flypass;
```

## Instrucciones para Ejecutar la Migración con Liquibase

### 1. Configurar archivo `liquibase.properties`:

```properties
changeLogFile: db.changelog-master.xml
driver: oracle.jdbc.OracleDriver
url: jdbc:oracle:thin:@localhost:1521/XEPDB1
username: flypass
password: flypass
logLevel: info
```

### 2. Ejecutar Liquibase:

```bash
# Con Docker (recomendado)
docker-compose up liquibase

# O manualmente si Liquibase está instalado localmente
liquibase update
```

### 3. Verificar la aplicación correcta de los changesets:

```sql
SELECT id, author, exectype, description
FROM flypass.databasechangelog
ORDER BY dateexecuted;
```

## Bloques Anónimos para Ejecutar los Procedimientos

### Procesar transacciones pendientes

```sql
BEGIN
  FLYPASS.PKG_PROCESOS_FLYPASS.PROCESAR_PASOS_PEAJES(p_max_registros => 1000);
END;
/
```

### Procesar notificaciones encoladas

```sql
BEGIN
  FLYPASS.PKG_NOTIFICACIONES_CONSUMER.PROCESAR_MENSAJES_ENCOLADOS(p_limit => 100);
END;
/
```

### Configurar job programado (opcional)

```sql
BEGIN
  DBMS_SCHEDULER.CREATE_JOB (
    job_name        => 'JOB_PROCESAR_PEAJES',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'FLYPASS.PKG_PROCESOS_FLYPASS.PROCESAR_PASOS_PEAJES',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=3',
    enabled         => TRUE,
    comments        => 'Procesamiento de peajes cada 3 minutos');
END;
/
```

## Conexión a la Base de Datos

Puedes conectarte a la base de datos Oracle usando estos parámetros:

- **Host**: localhost
- **Puerto**: 1521
- **Servicio**: XEPDB1
- **Usuario**: flypass
- **Contraseña**: flypass

## Consideraciones Adicionales

- El sistema está diseñado para manejar **grandes volúmenes de datos**, con especial atención al rendimiento y la escalabilidad
- La **arquitectura asíncrona** garantiza que el proceso principal de liquidación no se vea afectado por la generación de notificaciones
- El uso de **Liquibase** facilita la gestión de cambios y el despliegue en diferentes entornos
- El código incluye **comentarios detallados** para facilitar su mantenimiento

---

*Esta documentación proporciona una guía completa para la implementación, configuración y uso del sistema de procesamiento batch asíncrono con Oracle y Liquibase.*