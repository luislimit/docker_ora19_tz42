DROP VIEW GIMS_C1_CP.VW_COMP_DATO_PROVEEDOR;

CREATE OR REPLACE VIEW GIMS_C1_CP.VW_COMP_DATO_PROVEEDOR AS
SELECT 
		            proveedor.id_proveedor              AS "ID_PROVEEDOR"
		            ,tipoIdentificador.codigo           AS "TIPO_DOC"
		           ,persona.doc_ident                   AS "DOC_IDENT"
		           ,tipoPersona.descripcion             AS "TIPO_PERSONA"
		           ,persona.id_persona                  AS "ID_PERSONA"  
		           ,persona.nombre_completo             AS "NOMBRE_COMPLETO" 
		           ,personaj.razon_social               AS "RAZON_SOCIAL"
		           ,personaj.nombre_comercial           AS "NOMBRE_COMERCIAL"       
		           ,tipoproveedor.descripcion           AS "TIPO_PROVEEDOR"
		           ,CASE proveedor.ctl_estado
		                WHEN 1 THEN 
		                    'VIGOR'
		                ELSE 'ANULADO'
		            END
		                                                AS "ESTADO"       
		           ,tipodomicilio.descripcion           AS "DOMICILIO_TIPO"
		           ,tipovia.descripcion                 AS "DOMICILIO_TIPO_VIA"
		           ,proveedordomicilio.via              AS "DOMICILIO_VIA" 
		           ,proveedordomicilio.num_via          AS "DOMICILIO_NUM"
               ,proveedordomicilio.piso             AS "DOMICILIO_PISO" 
		           ,proveedordomicilio.puerta           AS "DOMICILIO_PUERTA"
               ,proveedordomicilio.kilometro        AS "DOMICILIO_KILOMETRO" 
               ,proveedordomicilio.ubicacion        AS "DOMICILIO_UBICACION" 
               ,proveedordomicilio.bloque           AS "DOMICILIO_BLOQUE"                
		           ,proveedordomicilio.COD_POSTAL       AS "DOMICILIO_COD_POSTAL"
		           ,loc.DESCRIPCION                     AS "DOMICILIO_LOCALIDAD"
		           ,mun.DESCRIPCION                     AS "DOMICILIO_MUNICIPIO"
		           ,prov.DESCRIPCION                    AS "DOMICILIO_PROVINCIA"
		           ,tipotel.descripcion                 as "TIPO_TELEFONO"
		           ,proveedortelefono.tlfn              AS "TELEFONO"
		           ,proveedorEmail.email                AS "EMAIL" 
		           FROM 
		                  GIMS_C1_FI.TR_PERSONA persona
		                 INNER JOIN GIMS_C1_FI.TR_PROVEEDOR proveedor 
		                    ON proveedor.id_persona = persona.id_persona
		                 INNER JOIN GIMS.tm_tipo_persona tipoPersona 
		                   ON (tipoPersona.ID_TIPO_PERSONA=proveedor.id_tipo_persona)
		                 LEFT JOIN GIMS_C1_FI.tr_persona_fisica personaF 
		                    on personaF.id_persona = persona.id_persona
		                 LEFT JOIN GIMS_C1_FI.tr_persona_juridica personaJ 
		                    on personaJ.id_persona = persona.id_persona
		                 INNER JOIN GIMS_C1_GE.tm_tipo_identificador tipoIdentificador
		                    ON (persona.id_tipo_ident = tipoIdentificador.id_tipo_ident)
		                 /*LEFT JOIN GIMS_C1_SA.tr_ps_prestador prestador
		                    ON (proveedor.id_proveedor = prestador.id_proveedor)*/
		                 INNER JOIN GIMS_C1_GE.vw_tipo_proveedor_locale tipoProveedor 
		                    on tipoProveedor.ID_TIPO_PROVEEDOR=proveedor.ID_TIPO_PROVEEDOR                          
		                 /*LEFT JOIN GIMS_C1_GE.vw_ps_situac_prestador_locale sitPrestador 
		                    on (sitPrestador.ID_PS_SITUAC_PRESTADOR=PRESTADOR.ID_PS_SITUAC_PRESTADOR)*/
		                 --DOMICILIO
		                 LEFT JOIN GIMS_C1_FI.tr_proveedor_domicilio proveedorDomicilio 
		                    ON (proveedordomicilio.id_proveedor = proveedor.id_proveedor AND proveedordomicilio.IND_USO =1 )
		                 LEFT JOIN GIMS_C1_GE.tm_tipo_domicilio tipoDomicilio
		                   ON (proveedordomicilio.id_tipo_domicilio = tipoDomicilio.id_tipo_domicilio )
		                 LEFT JOIN GIMS_C1_GE.tm_tipo_via tipoVia
		                   ON (proveedordomicilio.id_tipo_via = tipovia.id_tipo_via)
		                 LEFT JOIN gims_c1_ge.tr_localidad loc 
		                    on (loc.id_localidad = proveedorDomicilio.id_localidad)
						 LEFT JOIN gims_c1_ge.tr_municipio mun 
		                    on (mun.id_municipio = loc.id_municipio)
						 LEFT JOIN gims_c1_ge.vw_provincia prov 
		                    on (prov.id_provincia = mun.id_provincia)  
		                 --TELEFONO
		                 LEFT JOIN GIMS_C1_FI.tr_proveedor_telefono proveedorTelefono
		                   ON (proveedortelefono.id_proveedor =  proveedor.id_proveedor and proveedortelefono.ind_uso =1 )
		                 LEFT JOIN GIMS_C1_GE.tm_tipo_tlfn tipoTel
		                   ON (tipotel.id_tipo_tlfn = proveedorTelefono.id_tipo_tlfn)
		                  --EMAIL
		                 LEFT JOIN GIMS_C1_FI.tr_proveedor_email proveedorEmail
		                   ON (proveedorEmail.id_proveedor =  proveedor.id_proveedor and proveedorEmail.ind_uso =1 )
		           ORDER by persona.doc_ident;

DROP VIEW GIMS_C1_SI.VW_EX_CONSULTA_SINIESTRO;
DROP VIEW  GIMS_C1_SI.VW_EX_CONSULTA_SINIESTRO_MIN;
--DROP VIEW  GIMS_C1_CP.VW_COMP_DATO_PROVEEDOR; (Hay que recrearla antes DROP y CREATE)
DROP VIEW GIMS_C1_CP.VW_PRESTACION_VIDA_PERCEPTOR;
DROP VIEW GIMS_C1_FN.VW_FN_PAGO;
DROP PACKAGE BODY GIMS_C1_FN.PKG_LISTADOS_FINAN;
DROP VIEW GIMS_C1_PR.VW_PR_POLMOVIM_DD_NPOL;
DROP VIEW  GIMS_C1_PR.VW_PR_POLMOVIM_DD_VEHI;
