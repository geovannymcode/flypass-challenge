CREATE OR REPLACE PACKAGE BODY PKG_NOTIFICACIONES_CONSUMER AS
    PROCEDURE PROCESAR_MENSAJES_ENCOLADOS(p_limit IN PLS_INTEGER DEFAULT 100) IS
        v_dequeue_options      DBMS_AQ.DEQUEUE_OPTIONS_T;
        v_message_properties   DBMS_AQ.MESSAGE_PROPERTIES_T;
        v_message_handle       RAW(16);
        v_notificacion         TYP_NOTIFICACION_PAYLOAD;
        v_count                PLS_INTEGER := 0;
        
    BEGIN
        -- Configurar opciones de dequeue
        v_dequeue_options.wait := 1; -- 1 segundo de espera
        v_dequeue_options.navigation := DBMS_AQ.FIRST_MESSAGE;
        
        -- Procesar mensajes
        LOOP
            BEGIN
                -- Intentar dequeue
                DBMS_AQ.DEQUEUE(
                    queue_name => 'Q_NOTIFICACIONES',
                    dequeue_options => v_dequeue_options,
                    message_properties => v_message_properties,
                    payload => v_notificacion,
                    msgid => v_message_handle
                );
                
                -- Procesamiento asíncrono de la notificación
                -- En un entorno real, aquí se implementaría:
                -- 1. Envío de SMS/Email al cliente
                -- 2. Registro en sistema de monitorización
                -- 3. Actualización de estadísticas
                
                -- Para este desafío, simularemos el procesamiento con logs
                DBMS_OUTPUT.PUT_LINE('=== Procesando notificación ===');
                DBMS_OUTPUT.PUT_LINE('Tipo: ' || v_notificacion.TIPO_NOTIFICACION);
                DBMS_OUTPUT.PUT_LINE('Cliente: ' || v_notificacion.ID_CLIENTE);
                DBMS_OUTPUT.PUT_LINE('Mensaje: ' || v_notificacion.MENSAJE);
                DBMS_OUTPUT.PUT_LINE('============================');
                
                -- Actualizar contador y configurar para siguiente mensaje
                v_count := v_count + 1;
                v_dequeue_options.navigation := DBMS_AQ.NEXT_MESSAGE;
                
                -- Realizar commit para confirmar procesamiento
                COMMIT;
                
                -- Salir si alcanzamos el límite
                EXIT WHEN v_count >= p_limit;
                
            EXCEPTION
                WHEN DBMS_AQ.NO_DATA_FOUND THEN
                    -- No hay más mensajes
                    DBMS_OUTPUT.PUT_LINE('No hay más mensajes para procesar.');
                    EXIT;
                WHEN OTHERS THEN
                    -- Error en procesamiento
                    DBMS_OUTPUT.PUT_LINE('Error procesando notificación: ' || SQLERRM);
                    -- Avanzar al siguiente mensaje
                    v_dequeue_options.navigation := DBMS_AQ.NEXT_MESSAGE;
                    -- Hacer commit para evitar bloqueos
                    COMMIT;
            END;
        END LOOP;
        
        DBMS_OUTPUT.PUT_LINE('Total notificaciones procesadas: ' || v_count);
        
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Error general: ' || SQLERRM);
            ROLLBACK;
    END PROCESAR_MENSAJES_ENCOLADOS;
END PKG_NOTIFICACIONES_CONSUMER;
/