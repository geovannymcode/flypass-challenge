CREATE OR REPLACE PACKAGE BODY PKG_PROCESOS_FLYPASS AS

    PROCEDURE PROCESAR_PASOS_PEAJES(p_max_registros IN PLS_INTEGER DEFAULT 10000) IS
        -- Variables para control del proceso
        v_registros_procesados PLS_INTEGER := 0;
        v_id_lote VARCHAR2(50);
        v_limit PLS_INTEGER := LEAST(BATCH_SIZE, p_max_registros);
        
        -- Tipos para BULK COLLECT
        TYPE t_pasos_arr IS TABLE OF PASOS_PEAJES_PENDIENTES%ROWTYPE;
        v_pasos t_pasos_arr;
        
        -- Arrays para actualizaciones masivas
        TYPE t_id_paso_arr IS TABLE OF PASOS_PEAJES_PENDIENTES.ID_PASO%TYPE;
        TYPE t_estado_arr IS TABLE OF PASOS_PEAJES_PENDIENTES.ESTADO%TYPE;
        TYPE t_mensaje_arr IS TABLE OF PASOS_PEAJES_PENDIENTES.MENSAJE_ERROR%TYPE;
        
        v_id_pasos t_id_paso_arr := t_id_paso_arr();
        v_estados t_estado_arr := t_estado_arr();
        v_mensajes t_mensaje_arr := t_mensaje_arr();
        
        -- Arrays para actualización de saldos
        TYPE t_id_cliente_arr IS TABLE OF CLIENTES.ID_CLIENTE%TYPE;
        TYPE t_saldo_arr IS TABLE OF CLIENTES.SALDO_ACTUAL%TYPE;
        
        v_id_clientes t_id_cliente_arr := t_id_cliente_arr();
        v_saldos_nuevos t_saldo_arr := t_saldo_arr();
        
        -- Arrays para transacciones
        TYPE t_transaccion_arr IS TABLE OF TRANSACCIONES%ROWTYPE;
        v_transacciones t_transaccion_arr := t_transaccion_arr();
        
        -- Variables para Oracle AQ
        v_enqueue_options    DBMS_AQ.ENQUEUE_OPTIONS_T;
        v_message_properties DBMS_AQ.MESSAGE_PROPERTIES_T;
        v_message_handle     RAW(16);
        v_notificacion       TYP_NOTIFICACION_PAYLOAD;
        
        -- Control de errores
        v_error_count PLS_INTEGER;
        
    BEGIN
        -- Generar un ID único para este lote de procesamiento
        v_id_lote := 'LOTE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF') || '_' || SYS_GUID();
        
        WHILE v_registros_procesados < p_max_registros LOOP
            -- 1. Marcar un lote de registros como "PROCESANDO" para evitar concurrencia
            UPDATE PASOS_PEAJES_PENDIENTES
            SET ESTADO = 'PROCESANDO',
                ID_LOTE_PROCESO = v_id_lote
            WHERE ID_PASO IN (
                SELECT ID_PASO
                FROM PASOS_PEAJES_PENDIENTES
                WHERE ESTADO = 'PENDIENTE'
                AND ID_LOTE_PROCESO IS NULL
                AND ROWNUM <= v_limit
            );
            
            -- Si no hay más registros para procesar, salir del bucle
            EXIT WHEN SQL%ROWCOUNT = 0;
            
            -- Confirmar la marca de registros
            COMMIT;
            
            -- 2. Recuperar los registros marcados para procesamiento
            SELECT *
            BULK COLLECT INTO v_pasos
            FROM PASOS_PEAJES_PENDIENTES
            WHERE ID_LOTE_PROCESO = v_id_lote
            AND ESTADO = 'PROCESANDO';
            
            -- 3. Procesar cada paso en el lote
            FOR i IN 1..v_pasos.COUNT LOOP
                DECLARE
                    v_id_paso PASOS_PEAJES_PENDIENTES.ID_PASO%TYPE := v_pasos(i).ID_PASO;
                    v_id_tag VEHICULOS_TAG.ID_TAG%TYPE := v_pasos(i).ID_TAG;
                    v_id_peaje PEAJES.ID_PEAJE%TYPE := v_pasos(i).ID_PEAJE;
                    v_valor_peaje NUMBER := v_pasos(i).VALOR_PEAJE;
                    v_fecha_hora DATE := v_pasos(i).FECHA_HORA_PASO;
                    
                    v_estado_tag VARCHAR2(10);
                    v_id_cliente NUMBER;
                    v_saldo_actual NUMBER;
                    v_exento_comision CHAR(1);
                    v_descuento NUMBER := 0;
                    v_comision NUMBER := 0;
                    v_valor_total NUMBER;
                    v_estado VARCHAR2(15) := 'OK';  -- Por defecto éxito
                    v_mensaje VARCHAR2(500);
                    v_transaccion TRANSACCIONES%ROWTYPE;
                    v_aplica_comision BOOLEAN := TRUE;
                    v_hora NUMBER;
                    v_tiene_membresia BOOLEAN := FALSE;
                    
                BEGIN
                    -- 3.1 Validación de TAG
                    BEGIN
                        SELECT ESTADO, ID_CLIENTE 
                        INTO v_estado_tag, v_id_cliente
                        FROM VEHICULOS_TAG 
                        WHERE ID_TAG = v_id_tag;
                        
                        IF v_estado_tag != 'ACTIVO' THEN
                            v_estado := 'ERROR';
                            v_mensaje := 'TAG en estado ' || v_estado_tag;
                            RAISE_APPLICATION_ERROR(-20001, v_mensaje);
                        END IF;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            v_estado := 'ERROR';
                            v_mensaje := 'TAG no encontrado';
                            RAISE_APPLICATION_ERROR(-20002, v_mensaje);
                    END;
                    
                    -- 3.2 Obtener información del cliente
                    SELECT SALDO_ACTUAL 
                    INTO v_saldo_actual
                    FROM CLIENTES 
                    WHERE ID_CLIENTE = v_id_cliente;
                    
                    -- 3.3 Información del peaje
                    SELECT EXENTO_COMISION 
                    INTO v_exento_comision
                    FROM PEAJES 
                    WHERE ID_PEAJE = v_id_peaje;
                    
                    -- 3.4 Cálculo de descuento "Happy Hour" (22:00 a 05:00)
                    v_hora := TO_NUMBER(TO_CHAR(v_fecha_hora, 'HH24'));
                    IF v_hora >= 22 OR v_hora < 5 THEN
                        v_descuento := v_valor_peaje * 0.5;
                    END IF;
                    
                    -- 3.5 Verificar membresía activa para exención de comisión
                    BEGIN
                        SELECT COUNT(1) > 0
                        INTO v_tiene_membresia
                        FROM MEMBRESIAS_CLIENTE mc
                        WHERE mc.ID_CLIENTE = v_id_cliente
                        AND mc.ID_MEMBRESIA = 10 -- PLAN SOLO PEAJES
                        AND mc.FECHA_INICIO <= v_fecha_hora
                        AND (mc.FECHA_FIN IS NULL OR mc.FECHA_FIN >= v_fecha_hora);
                        
                        IF v_tiene_membresia THEN
                            v_aplica_comision := FALSE;
                        END IF;
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_tiene_membresia := FALSE;
                    END;
                    
                    -- 3.6 Cálculo de comisión (10%)
                    -- Primero verificar si el peaje está exento (prioridad sobre membresía)
                    IF v_exento_comision = 'S' THEN
                        v_aplica_comision := FALSE;
                    END IF;
                    
                    IF v_aplica_comision THEN
                        v_comision := (v_valor_peaje - v_descuento) * 0.1;
                    END IF;
                    
                    -- 3.7 Cálculo del total a cobrar
                    v_valor_total := (v_valor_peaje - v_descuento) + v_comision;
                    
                    -- 3.8 Validación de saldo
                    IF v_saldo_actual < v_valor_total THEN
                        v_estado := 'ERROR';
                        v_mensaje := 'Saldo insuficiente: ' || v_saldo_actual || ' < ' || v_valor_total;
                        RAISE_APPLICATION_ERROR(-20003, v_mensaje);
                    END IF;
                    
                    -- 3.9 Preparar para actualización masiva (sólo si OK)
                    v_id_clientes.EXTEND;
                    v_saldos_nuevos.EXTEND;
                    v_id_clientes(v_id_clientes.COUNT) := v_id_cliente;
                    v_saldos_nuevos(v_saldos_nuevos.COUNT) := v_saldo_actual - v_valor_total;
                    
                    -- 3.10 Preparar transacción
                    v_transaccion.ID_TRANSACCION := SEQ_TRANSACCIONES.NEXTVAL;
                    v_transaccion.ID_PASO := v_id_paso;
                    v_transaccion.ID_CLIENTE := v_id_cliente;
                    v_transaccion.FECHA_PROCESO := SYSDATE;
                    v_transaccion.VALOR_BASE := v_valor_peaje;
                    v_transaccion.VALOR_DESCUENTO := v_descuento;
                    v_transaccion.VALOR_COMISION := v_comision;
                    v_transaccion.VALOR_TOTAL_COBRADO := v_valor_total;
                    v_transaccion.SALDO_ANTERIOR := v_saldo_actual;
                    v_transaccion.SALDO_FINAL := v_saldo_actual - v_valor_total;
                    v_transaccion.ESTADO_TRANSACCION := 'COMPLETADA';
                    v_transaccion.DESCRIPCION := 'Procesado correctamente';
                    
                    v_transacciones.EXTEND;
                    v_transacciones(v_transacciones.COUNT) := v_transaccion;
                    
                EXCEPTION
                    WHEN OTHERS THEN
                        v_estado := 'ERROR';
                        v_mensaje := SUBSTR(SQLERRM, 1, 500);
                        
                        -- Preparar transacción para caso de error
                        v_transaccion.ID_TRANSACCION := SEQ_TRANSACCIONES.NEXTVAL;
                        v_transaccion.ID_PASO := v_id_paso;
                        v_transaccion.ID_CLIENTE := v_id_cliente;
                        v_transaccion.FECHA_PROCESO := SYSDATE;
                        v_transaccion.VALOR_BASE := v_valor_peaje;
                        v_transaccion.VALOR_DESCUENTO := 0;
                        v_transaccion.VALOR_COMISION := 0;
                        v_transaccion.VALOR_TOTAL_COBRADO := 0;
                        v_transaccion.SALDO_ANTERIOR := v_saldo_actual;
                        v_transaccion.SALDO_FINAL := v_saldo_actual;
                        v_transaccion.ESTADO_TRANSACCION := 'RECHAZADA';
                        v_transaccion.DESCRIPCION := v_mensaje;
                        
                        v_transacciones.EXTEND;
                        v_transacciones(v_transacciones.COUNT) := v_transaccion;
                END;
                
                -- 3.11 Encolar notificación de forma asíncrona
                v_notificacion := TYP_NOTIFICACION_PAYLOAD(
                    ID_CLIENTE => v_id_cliente,
                    ID_PASO => v_id_paso,
                    TIPO_NOTIFICACION => CASE 
                                           WHEN v_estado = 'OK' THEN 'PROCESADO_OK'
                                           WHEN v_mensaje LIKE '%Saldo insuficiente%' THEN 'ERROR_SALDO'
                                           ELSE 'ERROR_TAG'
                                         END,
                    FECHA_EVENTO => SYSDATE,
                    MENSAJE => CASE 
                                WHEN v_estado = 'OK' THEN 'Transacción procesada: ' || TO_CHAR(v_valor_total)
                                ELSE 'Error: ' || v_mensaje
                               END,
                    DATOS_ADICIONALES => 'Peaje=' || v_id_peaje || ';Tag=' || v_id_tag
                );
                
                DBMS_AQ.ENQUEUE(
                    queue_name => 'Q_NOTIFICACIONES',
                    enqueue_options => v_enqueue_options,
                    message_properties => v_message_properties,
                    payload => v_notificacion,
                    msgid => v_message_handle
                );
                
                -- Guardar estado para actualización masiva
                v_id_pasos.EXTEND;
                v_estados.EXTEND;
                v_mensajes.EXTEND;
                v_id_pasos(v_id_pasos.COUNT) := v_id_paso;
                v_estados(v_estados.COUNT) := v_estado;
                v_mensajes(v_mensajes.COUNT) := v_mensaje;
            END LOOP;
            
            -- 4. Actualizar estados de pasos pendientes usando FORALL
            BEGIN
                FORALL i IN 1..v_id_pasos.COUNT SAVE EXCEPTIONS
                    UPDATE PASOS_PEAJES_PENDIENTES
                    SET ESTADO = v_estados(i),
                        MENSAJE_ERROR = v_mensajes(i),
                        ID_LOTE_PROCESO = NULL
                    WHERE ID_PASO = v_id_pasos(i);
            EXCEPTION
                WHEN OTHERS THEN
                    IF SQLCODE = -24381 THEN -- ORA-24381: error(s) in array DML
                        v_error_count := SQL%BULK_EXCEPTIONS.COUNT;
                        FOR i IN 1..v_error_count LOOP
                            DBMS_OUTPUT.PUT_LINE('Error en actualización de paso ' || 
                                v_id_pasos(SQL%BULK_EXCEPTIONS(i).ERROR_INDEX) || 
                                ': ' || SQLERRM(-SQL%BULK_EXCEPTIONS(i).ERROR_CODE));
                        END LOOP;
                    ELSE
                        RAISE;
                    END IF;
            END;
            
            -- 5. Actualizar saldos de clientes
            IF v_id_clientes.COUNT > 0 THEN
                BEGIN
                    FORALL i IN 1..v_id_clientes.COUNT SAVE EXCEPTIONS
                        UPDATE CLIENTES
                        SET SALDO_ACTUAL = v_saldos_nuevos(i)
                        WHERE ID_CLIENTE = v_id_clientes(i);
                EXCEPTION
                    WHEN OTHERS THEN
                        IF SQLCODE = -24381 THEN
                            v_error_count := SQL%BULK_EXCEPTIONS.COUNT;
                            FOR i IN 1..v_error_count LOOP
                                DBMS_OUTPUT.PUT_LINE('Error en actualización de saldo cliente ' || 
                                    v_id_clientes(SQL%BULK_EXCEPTIONS(i).ERROR_INDEX) || 
                                    ': ' || SQLERRM(-SQL%BULK_EXCEPTIONS(i).ERROR_CODE));
                            END LOOP;
                        ELSE
                            RAISE;
                        END IF;
                END;
            END IF;
            
            -- 6. Insertar transacciones
            IF v_transacciones.COUNT > 0 THEN
                BEGIN
                    FORALL i IN 1..v_transacciones.COUNT SAVE EXCEPTIONS
                        INSERT INTO TRANSACCIONES VALUES v_transacciones(i);
                EXCEPTION
                    WHEN OTHERS THEN
                        IF SQLCODE = -24381 THEN
                            v_error_count := SQL%BULK_EXCEPTIONS.COUNT;
                            FOR i IN 1..v_error_count LOOP
                                DBMS_OUTPUT.PUT_LINE('Error en inserción de transacción ' || 
                                    i || ': ' || SQLERRM(-SQL%BULK_EXCEPTIONS(i).ERROR_CODE));
                            END LOOP;
                        ELSE
                            RAISE;
                        END IF;
                END;
            END IF;
            
            -- 7. COMMIT por lote
            COMMIT;
            
            -- Actualizar contador y reiniciar arrays
            v_registros_procesados := v_registros_procesados + v_pasos.COUNT;
            v_id_pasos.DELETE;
            v_estados.DELETE;
            v_mensajes.DELETE;
            v_id_clientes.DELETE;
            v_saldos_nuevos.DELETE;
            v_transacciones.DELETE;
        END LOOP;
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Log error y hacer rollback
            DBMS_OUTPUT.PUT_LINE('Error en procesamiento: ' || SQLERRM);
            ROLLBACK;
            
            -- Liberar registros bloqueados
            UPDATE PASOS_PEAJES_PENDIENTES
            SET ESTADO = 'PENDIENTE',
                ID_LOTE_PROCESO = NULL
            WHERE ID_LOTE_PROCESO = v_id_lote;
            COMMIT;
    END PROCESAR_PASOS_PEAJES;
    
END PKG_PROCESOS_FLYPASS;
/