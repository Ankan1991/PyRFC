# Copyright 2013 SAP AG.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http: //www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

""" The _pyrfc C-extension module """

import sys
import signal
import time
import datetime
import collections
import locale
from decimal import Decimal
from csapnwrfc cimport *

from pyrfc._exception import *

# inverts the enumeration of RFC_DIRECTION
_direction2rfc = {'RFC_IMPORT': RFC_IMPORT, 'RFC_EXPORT': RFC_EXPORT,
                  'RFC_CHANGING': RFC_CHANGING, 'RFC_TABLES': RFC_TABLES}

# inverts the enum of RFCTYPE
_type2rfc = {
    'RFCTYPE_CHAR': RFCTYPE_CHAR,
    'RFCTYPE_DATE': RFCTYPE_DATE,
    'RFCTYPE_BCD': RFCTYPE_BCD,
    'RFCTYPE_TIME': RFCTYPE_TIME,
    'RFCTYPE_BYTE': RFCTYPE_BYTE,
    'RFCTYPE_TABLE': RFCTYPE_TABLE,
    'RFCTYPE_NUM': RFCTYPE_NUM,
    'RFCTYPE_FLOAT': RFCTYPE_FLOAT,
    'RFCTYPE_INT': RFCTYPE_INT,
    'RFCTYPE_INT2': RFCTYPE_INT2,
    'RFCTYPE_INT1': RFCTYPE_INT1,
    'RFCTYPE_INT8': RFCTYPE_INT8,
    'RFCTYPE_STRUCTURE': RFCTYPE_STRUCTURE,
    'RFCTYPE_STRING': RFCTYPE_STRING,
    'RFCTYPE_XSTRING': RFCTYPE_XSTRING
}

# configuration bitmasks, internal use
_MASK_DTIME = 0x01
_MASK_RETURN_IMPORT_PARAMS = 0x02
_MASK_RSTRIP = 0x04

# NOTES ON ERROR HANDLING
# If an error occurs within a connection object, the error may - depending
# on the error code - affect the status of the connection object.
# Therefore, the _error() method is called instead of raising the error
# directly.
# However, updating the connection status is not possible in the
# fill/wrap-functions, as there is no connection object available. But this
# should not be a problem as we do not expect connection-affecting errors if
# no connection is present.
#
# NOTES ON NOGIL:
# NW RFC Lib function call may take a while (e.g. invoking RFC),
# other threads may be blocked meanwhile. To avoid this, some statements
# calling NW RFC Lib functions are executed within a "with nogil:" block,
# thereby releasing the Python global interpreter lock (GIL).


################################################################################
# NW RFC LIB FUNCTIONALITY
################################################################################

def get_nwrfclib_version():
    """Get SAP NW RFC Lib version
    :returns: tuple of major, minor and patch level
    """
    cdef unsigned major = 0
    cdef unsigned minor = 0
    cdef unsigned patchlevel = 0
    RfcGetVersion(&major, &minor, &patchlevel)
    return (major, minor, patchlevel)

################################################################################
# CLIENT FUNCTIONALITY
################################################################################

cdef class Connection:
    """ A connection to an SAP backend system

    Instantiating an :class:`pyrfc.Connection` object will
    automatically attempt to open a connection the SAP backend.

    :param config: Configuration of the instance. Allowed keys are:

           ``rstrip``
             right strips strings returned from RFC call (default is True)
           ``return_import_params``
             importing parameters are returned by the RFC call (default is False)

    :type config: dict or None (default)

    :param params: SAP connection parameters. The parameters consist of
           ``client``, ``user``, ``passwd``, ``lang``, ``trace``
           and additionally one of

           * Direct application server logon: ``ashost``, ``sysnr``.
           * Logon with load balancing: ``mshost``, ``msserv``, ``sysid``,
             ``group``.
             ``msserv`` is needed only, if the service of the message server
             is not defined as sapms<SYSID> in /etc/services.
           * When logging on with SNC, ``user`` and ``passwd`` are to be replaced by
             ``snc_qop``, ``snc_myname``, ``snc_partnername``, and optionally
             ``snc_lib``.
             (If ``snc_lib`` is not specified, the RFC library uses the "global" GSS library
             defined via environment variable SNC_LIB.)

    :type params: Keyword parameters

    :raises: :exc:`~pyrfc.RFCError` or a subclass
             thereof if the connection attempt fails.
    """
    cdef unsigned paramCount
    cdef unsigned __bconfig
    cdef public object __config
    cdef public bint alive
    cdef bint active_transaction
    cdef bint active_unit
    cdef RFC_CONNECTION_HANDLE _handle
    cdef RFC_CONNECTION_PARAMETER *connectionParams
    cdef RFC_TRANSACTION_HANDLE _tHandle
    cdef RFC_UNIT_HANDLE _uHandle

    property version:
        def __get__(self):
            """Get SAP NW RFC SDK and PyRFC binding versions
            :returns: SAP NW RFC SDK major, minor, patch level and PyRFC binding version
            """
            cdef unsigned major = 0
            cdef unsigned minor = 0
            cdef unsigned patchlevel = 0
            RfcGetVersion(&major, &minor, &patchlevel)
            return {'major': major, 'minor': minor, 'patchLevel': patchlevel}

    property options:
        def __get__(self):
            return self.__config

    def __init__(self, config={}, **params):
        cdef RFC_ERROR_INFO errorInfo

        # set connection config, rstrip default True
        self.__config = {}
        self.__config['dtime'] = config.get('dtime', False)
        self.__config['return_import_params'] = config.get('return_import_params', False)
        self.__config['rstrip'] = config.get('rstrip', True)
        # set internal configuration
        self.__bconfig = 0
        if self.__config['dtime']:
            self.__bconfig |= _MASK_DTIME
        if self.__config['return_import_params']:
            self.__bconfig |= _MASK_RETURN_IMPORT_PARAMS
        if self.__config['rstrip']:
            self.__bconfig |= _MASK_RSTRIP

        self.paramCount = int(len(params))
        if self.paramCount < 3:
            raise RFCError("Connection parameters missing")
        self.connectionParams = <RFC_CONNECTION_PARAMETER*> malloc(self.paramCount * sizeof(RFC_CONNECTION_PARAMETER))
        cdef int i = 0
        for name, value in params.iteritems():
            self.connectionParams[i].name = fillString(name)
            self.connectionParams[i].value = fillString(value)
            i += 1
        self.alive = False
        self.active_transaction = False
        self.active_unit = False
        self._open()

    def __del__(self):
        for i in range(self.paramCount):
            free(<SAP_UC*> self.connectionParams[i].name)
            free(<SAP_UC*> self.connectionParams[i].value)
        free(self.connectionParams)
        self._close()

    def __enter__(self):
        return self

    def __exit__(self, type, value, traceback):
        self._close() # Although the _close() method is also called in the destructor, the
                      # explicit call assures the immediate closing to the connection.

    def open(self):
        self._open()

    def reopen(self):
        self._reopen()

    def close(self):
        """ Explicitly close the connection.

            Note that this is usually not necessary as the connection will be closed
            automatically upon object destruction. However, if the the object destruction
            is delayed by the garbage collection, problems may occur when too many
            connections are opened.
        """
        self._close()

    def __bool__(self):
        return self.alive

    cdef _reopen(self):
        self._close()
        self._open()

    cdef _open(self):
        cdef RFC_ERROR_INFO errorInfo
        with nogil:
            self._handle = RfcOpenConnection(self.connectionParams, self.paramCount, &errorInfo)
        if not self._handle:
            self._error(&errorInfo)
        self.alive = True

    def _close(self):
        """ Close the connection (private function)

        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof if the connection cannot be closed cleanly.
        """
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        if self.alive:
            rc = RfcCloseConnection(self._handle, &errorInfo)
            self.alive = False
            if rc != RFC_OK:
                self._error(&errorInfo)

    cdef _error(self, RFC_ERROR_INFO* errorInfo):
        """
        Error treatment of a connection.

        :param errorInfo: the errorInfo data given in a RFC that returned an RC > 0.
        :return: nothing, raises an error
        """
        # Set alive=false if the error is in a certain group
        # Before, the alive=false setting depended on the error code. However, the group seems more robust here.
        # (errorInfo.code in (RFC_COMMUNICATION_FAILURE, RFC_ABAP_MESSAGE, RFC_ABAP_RUNTIME_FAILURE, RFC_INVALID_HANDLE, RFC_NOT_FOUND, RFC_INVALID_PARAMETER):
        if errorInfo.group in (ABAP_RUNTIME_FAILURE, LOGON_FAILURE, COMMUNICATION_FAILURE, EXTERNAL_RUNTIME_FAILURE):
            self.alive = False

        raise wrapError(errorInfo)

    def ping(self):
        """ Send a RFC Ping through the current connection

        Returns nothing.

        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof if the RFC Ping fails.
        """
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        rc = RfcPing(self._handle, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)

    def reset_server_context(self):
        """ Resets the SAP server context ("user context / ABAP session context")
        associated with the given client connection, but does not close the connection

        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof in case resetting the server context fails.
                 (Better close the connection in that case.).
                 :exc:`sapnwrf2.CommunicationError` if no conversion
                 was found for the
        """

        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        if not self.alive:
            self._open()
        rc = RfcResetServerContext(self._handle, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)

    def get_connection_attributes(self):
        """ Get connection details

        :returns: Mapping of connection information keys:

                  * active_unit: True if there is a filled and submitted unit w/o being confirmed or destroyed.
                  * dest: RFC destination
                  * host: Own host name
                  * partnerHost: Partner host name
                  * sysNumber: R/3 system number
                  * sysId: R/3 system ID
                  * client: Client ("Mandant")
                  * user: User
                  * language: Language
                  * trace: Trace level (0-3)
                  * isoLanguage: 2-byte ISO-Language
                  * codepage: Own code page
                  * partnerCodepage: Partner code page
                  * rfcRole: C/S: RFC Client / RFC Server
                  * type: 2/3/E/R: R/2,R/3,Ext,Reg.Ext
                  * partnerType: 2/3/E/R: R/2,R/3,Ext,Reg.Ext
                  * rel: My system release
                  * partnerRe: Partner system release
                  * kernelRel: Partner kernel release
                  * cpicConvId: CPI-C Conversation ID
                  * progName: Name calling APAB program (report, module pool)
                  * partnerBytesPerChar: Bytes per char in backend codepage.
                  * partnerSystemCodepage: Partner system code page
                  * reserved: Reserved for later use

                Note: all values, except ``active_unit`` are right stripped
                string values.

        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof if the RFC call fails.
        """
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef RFC_ATTRIBUTES attributes
        cdef RFC_INT isValid

        rc = RfcIsConnectionHandleValid(self._handle, &isValid, &errorInfo);

        result = {}
        if (isValid and rc == RFC_OK):
            rc = RfcGetConnectionAttributes(self._handle, &attributes, &errorInfo)
            if rc != RFC_OK:
                self._error(&errorInfo)

            result = wrapConnectionAttributes(attributes)
            result.update({
                'active_unit': self.active_unit or self.active_transaction
            })
        return result

    def get_function_description(self, func_name):
        """ Returns a function description of a function module.

        :param func_name: Name of the function module whose description
              will be returned.
        :type func_name: string

        :return: A :class:`FunctionDescription` object.
        """
        cdef RFC_ERROR_INFO errorInfo
        funcName = fillString(func_name.upper())
        if not self.alive:
            self._open()
        cdef RFC_FUNCTION_DESC_HANDLE funcDesc = RfcGetFunctionDesc(self._handle, funcName, &errorInfo)
        free(funcName)
        if not funcDesc:
            self._error(&errorInfo)
        return wrapFunctionDescription(funcDesc)

    def call(self, func_name, options={}, **params):
        """ Invokes a remote-enabled function module via RFC.

        :param func_name: Name of the function module that will be invoked.
        :type func_name: string

        :param options: Call options, like 'skip', to deactivate certain parameters.
        :type options: dictionary

        :param params: Parameter of the function module. All non optional
              IMPORT, CHANGING, and TABLE parameters must be provided.
        :type params: keyword arguments

        :return: Dictionary with all EXPORT, CHANGING, and TABLE parameters.
              The IMPORT parameters are also given, if :attr:`Connection.config.return_import_params`
              is set to ``True``.

        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof if the RFC call fails.
        """
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef unsigned paramCount
        cdef SAP_UC *cName
        if type(func_name) is not str:
            if type(func_name) is not unicode:
                raise RFCError("Remote function module name must be unicode string, received:", func_name, type(func_name))
        cdef SAP_UC *funcName = fillString(func_name)
        if not self.alive:
            self._open()
        cdef RFC_FUNCTION_DESC_HANDLE funcDesc = RfcGetFunctionDesc(self._handle, funcName, &errorInfo)
        free(funcName)
        if not funcDesc:
            self._error(&errorInfo)
        cdef RFC_FUNCTION_HANDLE funcCont = RfcCreateFunction(funcDesc, &errorInfo)
        if not funcCont:
            self._error(&errorInfo)
        cdef int isActive = 0
        try: # now we have a function module
            if 'not_requested' in options:
                skip_parameters = options['not_requested']
                if not isinstance(skip_parameters, list):
                    skip_parameters = [skip_parameters]
                for name in skip_parameters:
                    cName = fillString(name)
                    rc = RfcSetParameterActive(funcCont, cName, isActive, &errorInfo)
                    free(cName)
                    if rc != RFC_OK:
                        self._error(&errorInfo)
            for name, value in params.iteritems():
                fillFunctionParameter(funcDesc, funcCont, name, value)
            with nogil:
                rc = RfcInvoke(self._handle, funcCont, &errorInfo)
            if rc != RFC_OK:
                self._error(&errorInfo)
            if self.__bconfig & _MASK_RETURN_IMPORT_PARAMS:
                return wrapResult(funcDesc, funcCont, <RFC_DIRECTION> 0, self.__bconfig)
            else:
                return wrapResult(funcDesc, funcCont, RFC_IMPORT, self.__bconfig)
        finally:
            RfcDestroyFunction(funcCont, NULL)

    ##########################################################################
    ## HELPER METHODS
    def type_desc_get(self, type_name):
        """Removes the Type Description from SAP NW RFC Lib cache

        :param type_name: system id (connection parameters sysid)
        :type type_name: string

        :returns: error code
        """
        cdef RFC_ERROR_INFO errorInfo
        typeName = fillString(type_name.upper())
        cdef RFC_TYPE_DESC_HANDLE typeDesc = RfcGetTypeDesc(self._handle, typeName, &errorInfo)
        free(typeName)
        if typeDesc == NULL:
            self._error(&errorInfo)
        return wrapTypeDescription(typeDesc)

    def type_desc_remove(self, sysid, type_name):
        """Removes the Type Description from SAP NW RFC Lib cache

        :param sysid: system id (connection parameters sysid)
        :type sysid: string

        :param type_name: Name of the type to be removed
        :type func_name: string

        :returns: error code
        """
        cdef RFC_ERROR_INFO errorInfo
        sysId = fillString(sysid)
        typeName = fillString(type_name)
        cdef RFC_RC rc = RfcRemoveTypeDesc(sysId, typeName, &errorInfo)
        free(sysId)
        free(typeName)
        if rc != RFC_OK:
            self._error(&errorInfo)
        return rc

    def func_desc_remove(self, sysid, func_name):
        """Removes the Function Description from SAP NW RFC Lib cache

        :param sysid: system id (connection parameters sysid)
        :type sysid: string

        :param func_name: Name of the function module to be removed
        :type func_name: string

        :returns: error code
        """
        cdef RFC_ERROR_INFO errorInfo
        sysId = fillString(sysid)
        funcName = fillString(func_name)
        cdef RFC_RC rc = RfcRemoveFunctionDesc(sysId, funcName, &errorInfo)
        free(sysId)
        free(funcName)
        if rc != RFC_OK:
            self._error(&errorInfo)
        return rc

    ##########################################################################
    ## TRANSACTIONAL / QUEUED RFC

    def _get_transaction_id(self):
        """ Returns a unique 24 char transaction ID (GUID)."""
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef RFC_TID tid

        if not self.alive:
            self._open()
        rc = RfcGetTransactionID(self._handle, tid, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)
        return wrapString(tid, RFC_TID_LN)

    def _create_and_submit_transaction(self, transaction_id, calls, queue_name=None):
        # Note: no persistence action is taken of maintaining the arguments (cf. Schmidt, Li (2009c), p. 5ff)
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef SAP_UC* queueName
        cdef RFC_FUNCTION_DESC_HANDLE funcDesc
        cdef RFC_FUNCTION_HANDLE funcCont

        if not self.alive:
            self._open()

        tid = fillString(transaction_id)
        queueName = NULL
        if queue_name:
            queueName = fillString(queue_name)
        self._tHandle = RfcCreateTransaction(self._handle, tid, queueName, &errorInfo)

        if queue_name:
            free(queueName)
        free(tid)
        if self._tHandle == NULL:
            self._error(&errorInfo)
        self.active_transaction = True

        try:
            for func_name, params in calls:
                funcName = fillString(func_name)
                funcDesc = RfcGetFunctionDesc(self._handle, funcName, &errorInfo)
                free(funcName)
                if not funcDesc:
                    self._error(&errorInfo)
                funcCont = RfcCreateFunction(funcDesc, &errorInfo)
                if not funcCont:
                    self._error(&errorInfo)
                try:
                    for name, value in params.iteritems():
                        fillFunctionParameter(funcDesc, funcCont, name, value)
                    # Add RFC call to transaction
                    rc = RfcInvokeInTransaction(self._tHandle, funcCont, &errorInfo)
                    if rc != RFC_OK:
                        self._error(&errorInfo)
                finally:
                    RfcDestroyFunction(funcCont, NULL)
            # execute
            with nogil:
                rc = RfcSubmitTransaction(self._tHandle, &errorInfo)
            if rc != RFC_OK:
                self._error(&errorInfo)

        except RFCError as e:
            # clean up actions
            RfcDestroyTransaction(self._tHandle, NULL)
            raise

    def _destroy_transaction(self):
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        if not self.active_transaction:
            raise RFCError("No transaction handle for this connection available.")
        if not self.alive:
            self._open()
        rc = RfcDestroyTransaction(self._tHandle, &errorInfo)
        self.active_transaction = False
        if rc != RFC_OK:
            self._error(&errorInfo)

    def _confirm_transaction(self):
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        if not self.active_transaction:
            raise RFCError("No transaction handle for this connection available.")
        if not self.alive:
            self._open()
        rc = RfcConfirmTransaction(self._tHandle, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)
        rc = RfcDestroyTransaction(self._tHandle, &errorInfo)
        self.active_transaction = False
        if rc != RFC_OK:
            self._error(&errorInfo)

    ##########################################################################
    ## BACKGROUND RFC

    def _get_unit_id(self):
        """Returns a unique 32 char bgRFC unit ID (GUID)."""
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef RFC_UNITID uid

        if not self.alive:
            self._open()
        rc = RfcGetUnitID(self._handle, uid, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)
        return wrapString(uid, RFC_UNITID_LN)

    def _create_and_submit_unit(self, unit_id, calls, queue_names=None, attributes=None):
        # Note: no persistence action is taken of maintaining the arguments (cf. Schmidt, Li (2009c), p. 5ff)
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef int queueNameCount
        #cdef const_SAP_UC_ptr* queueNames
        cdef SAP_UC** queueNames
        cdef RFC_UNIT_ATTRIBUTES unitAttr
        cdef RFC_UNIT_IDENTIFIER uIdentifier
        cdef RFC_FUNCTION_DESC_HANDLE funcDesc
        cdef RFC_FUNCTION_HANDLE funcCont
        cdef SAP_UC* sapuc

        if not self.alive:
            self._open()

        # uid
        uid = fillString(unit_id)
        # queue
        queue_names = queue_names or []
        if len(queue_names) == 0:
            queueNameCount = 0
            queueNames = NULL
            #queueNames = <SAP_UC**> mallocU(queueNameCount * sizeof(SAP_UC*))
        else:
            queueNameCount = int(len(queue_names))
            queueNames = <SAP_UC**> mallocU(queueNameCount * sizeof(SAP_UC*))
            for i, queue_name in enumerate(queue_names):
                queueNames[i] = fillString(queue_name)
        # attributes
        # set default values
        memsetR(&unitAttr, 0, sizeof(RFC_UNIT_ATTRIBUTES))
        memsetR(&uIdentifier, 0, sizeof(RFC_UNIT_IDENTIFIER))
#        unitAttr.kernelTrace = 0        # (short) If != 0, the backend will write kernel traces, while executing this unit.
#        unitAttr.satTrace = 0           # (short) If != 0, the backend will keep a "history" for this unit.
#        unitAttr.unitHistory = 0        # (short) Used only for type Q: If != 0, the unit will be written to the queue, but not processed. The unit can then be started manually in the ABAP debugger.
#        unitAttr.lock = 0               # (short) Used only for type Q: If != 0, the unit will be written to the queue, but not processed. The unit can then be started manually in the ABAP debugger.
#        unitAttr.noCommitCheck = 0		# (short) Per default the backend will check during execution of a unit, whether one of the unit's function modules triggers an explicit or implicit COMMIT WORK. In this case the unit is aborted with an error, because the transactional integrity of this unit cannot be guaranteed. By setting "noCommitCheck" to true (!=0), this behavior can be suppressed, meaning the unit will be executed anyway, even if one of it's function modules "misbehaves" and triggers a COMMIT WORK.
#        unitAttr.user[0] = '\0'         # (SAP_UC[12+1]) Sender User (optional). Default is current operating system User.
#        unitAttr.client[0] = '\0'         # (SAP_UC[3+1]) Sender Client ("Mandant") (optional). Default is "000".
#        unitAttr.tCode[0] = '\0'         # (SAP_UC[20+1]) Sender Transaction Code (optional). Default is "".
#        unitAttr.program[0] = '\0'         # (SAP_UC[40+1]) Sender Program (optional). Default is current executable name.
#        unitAttr.hostname[0] = '\0'         # (SAP_UC hostname[40+1];			///< Sender hostname. Used only when the external program is server. In the client case the nwrfclib fills this automatically.:1591
        #unitAttr.sendingDate[0] = '\0'         # (RFC_DATE sendingDate;			///< Sending date in UTC (GMT-0). Used only when the external program is server. In the client case the nwrfclib fills this automatically.
        #unitAttr.sendingTime[0] = '\0'         # (RFC_TIME sendingTime;			///< Sending time in UTC (GMT-0). Used only when the external program is server. In the client case the nwrfclib fills this automatically.
        if attributes is not None:
            if 'kernel_trace' in attributes:
                unitAttr.kernelTrace = attributes['kernel_trace']
            if 'sat_trace' in attributes:
                unitAttr.satTrace = attributes['sat_trace']
            if 'unit_history' in attributes:
                unitAttr.unitHistory = attributes['unit_history']
            if 'lock' in attributes:
                unitAttr.lock = attributes['lock']
            if 'no_commit_check' in attributes:
                unitAttr.noCommitCheck = attributes['no_commit_check']
            if 'user' in attributes and attributes['user'] is not None: # (SAP_UC[12+1]) Sender User (optional). Default is current operating system User.
                sapuc = fillString(attributes['user'][0:12])
                strncpyU(unitAttr.user, sapuc, len(attributes['user'][0:12]) + 1)
                free(sapuc)
            if 'client' in attributes: # (SAP_UC[3+1]) Sender Client ("Mandant") (optional). Default is "000".
                sapuc = fillString(attributes['client'][0:3])
                strncpyU(unitAttr.client, sapuc, len(attributes['client'][0:3]) + 1)
                free(sapuc)
            if 't_code' in attributes: # (SAP_UC[20+1]) Sender Transaction Code (optional). Default is "".
                sapuc = fillString(attributes['t_code'][0:20])
                strncpyU(unitAttr.tCode, sapuc, len(attributes['t_code'][0:20]) + 1)
                free(sapuc)
            if 'program' in attributes and attributes['program'] is not None: # (SAP_UC[40+1]) Sender Program (optional). Default is current executable name.
                sapuc = fillString(attributes['program'][0:40])
                strncpyU(unitAttr.program, sapuc, len(attributes['program'][0:40]) + 1)
                free(sapuc)
        #unitAttr.hostname = "";		# (SAP_UC[40+1]) Sender hostname. Used only when the external program is server. In the client case the nwrfclib fills this automatically.
        #unitAttr.sendingDate;			# (RFC_DATE) Sending date in UTC (GMT-0). Used only when the external program is server. In the client case the nwrfclib fills this automatically.
        #unitAttr.sendingTime;			# (RFC_TIME) Sending time in UTC (GMT-0). Used only when the external program is server. In the client case the nwrfclib fills this automatically.

        self._uHandle = RfcCreateUnit(self._handle, uid, <const_SAP_UC_ptr*> queueNames, queueNameCount, &unitAttr, &uIdentifier, &errorInfo)

        # queue (deallocate)
        if len(queue_names) > 0:
            for i, queue_name in enumerate(queue_names):
                free(queueNames[i])
            free(queueNames)
        # uid (deallocate)
        free(uid)

        if self._uHandle == NULL:
            self._error(&errorInfo)
        self.active_unit = True

        try:
            for func_name, params in calls:
                funcName = fillString(func_name)
                funcDesc = RfcGetFunctionDesc(self._handle, funcName, &errorInfo)
                free(funcName)
                if not funcDesc:
                    self._error(&errorInfo)
                funcCont = RfcCreateFunction(funcDesc, &errorInfo)
                if not funcCont:
                    self._error(&errorInfo)
                try:
                    for name, value in params.iteritems():
                        fillFunctionParameter(funcDesc, funcCont, name, value)
                    # Add RFC call to unit
                    rc = RfcInvokeInUnit(self._uHandle, funcCont, &errorInfo)
                    if rc != RFC_OK:
                        self._error(&errorInfo)
                finally:
                    RfcDestroyFunction(funcCont, NULL)
            # TODO: segfault here. FIXME
            # execute
            #_# print " Invocation finished. submitting unit."
            #with nogil:
            rc = RfcSubmitUnit(self._uHandle, &errorInfo)
            if rc != RFC_OK:
                self._error(&errorInfo)

        except RFCError as e:
            # clean up actions
            RfcDestroyUnit(self._uHandle, NULL)
            raise

        #_#print " - wrapping Unit IDentifier."
        unit_identifier = wrapUnitIdentifier(uIdentifier)
        return unit_identifier["queued"]

    def _get_unit_state(self, unit):
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef RFC_UNIT_IDENTIFIER uIdentifier = fillUnitIdentifier(unit)
        cdef RFC_UNIT_STATE state
        unit_state2txt = {
            RFC_UNIT_NOT_FOUND: u"RFC_UNIT_NOT_FOUND",
            RFC_UNIT_IN_PROCESS: u"RFC_UNIT_IN_PROCESS",
            RFC_UNIT_COMMITTED: u"RFC_UNIT_COMMITTED",
            RFC_UNIT_ROLLED_BACK: u"RFC_UNIT_ROLLED_BACK",
            RFC_UNIT_CONFIRMED: u"RFC_UNIT_CONFIRMED"
        }

        if not self.active_unit:
            raise RFCError(u"No unit handle for this connection available.")
        if not self.alive:
            self._open()
        rc = RfcGetUnitState(self._handle, &uIdentifier, &state, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)
        return unit_state2txt[state]


    def _destroy_unit(self):
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        if not self.active_unit:
            raise RFCError("No unit handle for this connection available.")
        if not self.alive:
            self._open()
        rc = RfcDestroyUnit(self._uHandle, &errorInfo)
        self.active_unit = False
        if rc != RFC_OK:
            self._error(&errorInfo)

    def _confirm_unit(self, unit):
        cdef RFC_RC rc
        cdef RFC_ERROR_INFO errorInfo
        cdef RFC_UNIT_IDENTIFIER uIdentifier = fillUnitIdentifier(unit)

        if not self.active_unit:
            raise RFCError("No unit handle for this connection available.")
        if not self.alive:
            self._open()
        rc = RfcConfirmUnit(self._handle, &uIdentifier, &errorInfo)
        if rc != RFC_OK:
            self._error(&errorInfo)
        rc = RfcDestroyUnit(self._uHandle, &errorInfo)
        self.active_unit = False
        if rc != RFC_OK:
            self._error(&errorInfo)

    ##########################################################################
    ## UNIT RFC

    # a "unit" for the client is a dictionary with up to three key-value pairs:
    # * background - boolean, set on initialize_unit() call
    # * id - string 24 or 32 chars, set on initialize_unit() call
    # * queued - boolean, set on fill_and_submit_unit() call

    def initialize_unit(self, background=True):
        """ Initializes a logical unit of work (LUW), shorthand: unit

        .. warning::

           The background protocol (bgRFC) is not working in the current version.
           Please use only tRFC/qRFC protocols.

        :param background: The bgRFC protocol will be used. If set to False,
               the t/qRFC protocol will be used. Note that the bgRFC protocol
               has extended functionality. Default: True
        :type background: boolean

        :returns: A dictionary describing the unit.
        """
        if background is True: # use bgRFC
            id = self._get_unit_id()
        elif background is False: # classic t/qRFC
            id = self._get_transaction_id()
        else:
            raise RFCError("Argument 'background' must be a boolean value.")
        return {'background': background, 'id':id}

    def fill_and_submit_unit(self, unit, calls, queue_names=None, attributes=None):
        """ Fills a unit with one or more RFC and submits it to the backend.

        Fills a unit for this connection, prepare the invocation
        of multiple RFC function modules in it, and submits the unit
        to the backend.

        Afterwards, the unit is still attached to the connection object,
        until confirm_unit() or destroy_unit() is called. Until one of these
        methods are called, no other unit could be filled and submitted.

        :param unit: a unit descriptor as returned by
               :meth:`~pyrfc.Connection.initialize_unit`.
        :param calls: a list of call descriptions. Each call description is a
               tuple that contains the function name as the first element and
               the function arguments in form of a dictionary as the second element.
        :param queue_names:
               If the unit uses the background protocol, various queue names can
               be given (leading to a asynchronous unit, type 'Q'). If parameter
               is an empty list or None, a synchronous unit (type 'T') is created.

               If the unit does not use the background protocol, the queue name
               may be a list with exactly one element, leading to a qRFC, or
               an empty list or None, leading to a tRFC.
        :type queue_names: list of strings or None (default)
        :param attributes: optional argument for attributes of the unit -- only valid if the background protocol
              is used. The attributes dict may contain the following keywords:

              =============== ============================= ======================= ==========================================================================================
              keyword         default                       type                    description
              =============== ============================= ======================= ==========================================================================================
              kernel_trace    0                             int                     If != 0, the backend will write kernel traces, while executing this unit.
              sat_trace       0                             int                     If != 0, the backend will write statistic records, while executing this unit.
              unit_history    0                             int                     If != 0, the backend will keep a "history" for this unit.
              lock            0                             int                     Used only for type Q: If != 0, the unit will be written to the queue, but not processed.
                                                                                    The unit can then be started manually in the ABAP debugger.
              no_commit_check 0                             int                     Per default the backend will check during execution of a unit, whether one of the
                                                                                    unit's function modules triggers an explicit or implicit COMMITWORK.
                                                                                    In this case the unit is aborted with an error, because the transactional integrity of
                                                                                    this unit cannot be guaranteed. By setting "no_commit_check" to true (!=0), this behavior
                                                                                    can be suppressed, meaning the unit will be executed anyway, even if one of it's
                                                                                    function modules "misbehaves" and triggers a COMMIT WORK.
              user            current operating system user String, len |nbsp| 12   Sender User (optional).
              client          "000"                         String, len |nbsp| 3    Sender Client ("Mandant") (optional).
              t_code          ""                            String, len |nbsp| 20   Sender Transaction Code (optional).
              program         current executable name       String, len |nbsp| 40   Sender Program (optional).
              =============== ============================= ======================= ==========================================================================================

        :type attributes: dict or None (default)
        :raises: :exc:`~pyrfc.RFCError` or a subclass thereof if an error
                 occurred. In this case, the unit is destroyed.
        """

        if not isinstance(unit, dict) or 'id' not in unit or 'background' not in unit:
            raise TypeError("Parameter 'unit' not valid. Please use initialize_unit() to retrieve a valid unit.")
        if not isinstance(calls, collections.Iterable):
            raise TypeError("Parameter 'calls' must be iterable.")
        if len(calls)==0:
            raise TypeError("Parameter 'calls' must contain at least on call description (func_name, params).")
        for func_name, params in calls:
            if not isinstance(func_name, basestring) or not isinstance(params, dict):
                raise TypeError("Parameter 'calls' must contain valid call descriptions (func_name, params dict).")
        if self.active_unit:
            raise RFCError(u"There is an active unit for this connection. "
                           u"Use destroy_unit() " +
                           u"or confirm_unit().")
        bg = unit['background']
        unit_id = unit['id']

        if bg is True:
            if len(unit_id)!=RFC_UNITID_LN:
                raise TypeError("Length of parameter 'unit['id']' must be {} chars.".format(RFC_UNITID_LN))
            unit['queued'] = self._create_and_submit_unit(unit_id, calls, queue_names, attributes)
        elif bg is False:
            if len(unit_id)!=RFC_TID_LN:
                raise TypeError("Length of parameter 'unit['id']' must be {} chars.".format(RFC_TID_LN))
            if attributes is not None:
                raise RFCError("Argument 'attributes' not valid. (t/qRFC does not support attributes.)")
            if queue_names is None or isinstance(queue_names, list) and len(queue_names) == 0:
                self._create_and_submit_transaction(unit_id, calls)
                unit['queued'] = False
            elif len(queue_names) == 1:
                queue_name = queue_names[0]
                self._create_and_submit_transaction(unit_id, calls, queue_name)
                unit['queued'] = True
            else:
                raise RFCError("Argument 'queue_names' not valid. (t/qRFC only support one queue name.)")
        else:
            raise RFCError("Argument 'unit' not valid. (Is unit['background'] boolean?)")
        return unit

    def get_unit_state(self, unit):
        """Retrieves the processing status of the given background unit.

        .. note::
           Only available for background units.

        :param unit: a unit descriptor as returned by
               :meth:`~pyrfc.Connection.initialize_unit`.
        :return: The state of the current bgRFC unit. Possible values are:
            RFC_UNIT_NOT_FOUND
            RFC_UNIT_IN_PROCESS
            RFC_UNIT_COMMITTED
            RFC_UNIT_ROLLED_BACK
            RFC_UNIT_CONFIRMED
        """
        bg = unit['background']
        if bg is True:
            return self._get_unit_state(unit)
        elif bg is False:
            raise RFCError("No state check possible of non-bgRFC units.")
        else:
            raise RFCError("Argument 'unit' not valid. (Is unit['background'] boolean?)")

    def destroy_unit(self, unit):
        """ Destroy the current unit.

        E.g. if the completed unit could not be recorded in the frontend.

        :param unit: a unit descriptor as returned by
               :meth:`~pyrfc.Connection.initialize_unit`.
        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof if the connection attempt fails.
        """
        bg = unit['background']
        if bg is True:
            self._destroy_unit()
        elif bg is False:
            self._destroy_transaction()
        else:
            raise RFCError("Argument 'unit' not valid. (Is unit['background'] boolean?)")

    def confirm_unit(self, unit):
        """ Confirm the current unit in the backend.

        This also destroys the unit.

        :param unit: a unit descriptor as returned by
               :meth:`~pyrfc.Connection.initialize_unit`.
        :raises: :exc:`~pyrfc.RFCError` or a subclass
                 thereof if the connection attempt fails.
        """
        bg = unit['background']
        if bg is True:
            self._confirm_unit(unit)
        elif bg is False:
            self._confirm_transaction()
        else:
            raise RFCError("Argument 'unit' not valid. (Is unit['background'] boolean?)")

class TypeDescription(object):
    """ A type description

        This class wraps the RFC_TYPE_DESC_HANDLE as e.g. contained in
        a parameter description of a function description.

        :param name: Name of the type.
        :param nuc_length: Length of the type in non unicode systems.
        :param uc_length: Length of the type in unicode systems.

        *Attributes and methods*

        **name**
          The name of the function.

        **nuc_length**
          The length in bytes if chars are non unicode.

        **uc_length**
          The length in bytes if chars are unicode.

        **fields**
          The fields as a list of dicts.

    """
    def __init__(self, name, nuc_length, uc_length):
        self.fields = []
        if len(name)<1 or len(name)>30:
            raise TypeError("'name' (string) should be from 1-30 chars.")
        for int_field in [nuc_length, uc_length]:
            if not isinstance(int_field, (int, long)):
                raise TypeError("'{}' must be of type integer".format(int_field))
        self.name = name
        self.nuc_length = nuc_length
        self.uc_length = uc_length

    def add_field(self, name, field_type, nuc_length, uc_length, nuc_offset,
                  uc_offset, decimals=0, type_description=None):
        """ Adds a field to the type description.

        :param name: Field name
        :type name: string (30)
        :param field_type: Type of the field
        :type field_type: string
        :param nuc_length: NUC length
        :type nuc_length: int
        :param uc_length: UC length
        :type uc_length: int
        :param nuc_offset: NUC offset.
        :type nuc_offset: int
        :param uc_offset: UC offset.
        :type uc_offset: int
        :param decimals: Decimals (default=0)
        :type decimals: int
        :param type_description: An object of class TypeDescription or None (default=None)
        :type type_description: object of class TypeDescription
        """
        if len(name)<1:
            return None
        if len(name)>30:
            raise TypeError("'name' (string) should be from 1-30 chars.")
        if field_type not in _type2rfc:
            raise TypeError("'field_type' (string) must be in [" + ", ".join(_type2rfc) + "]")
        for int_field in [nuc_length, nuc_offset, uc_length, uc_offset]:
            if not isinstance(int_field, (int, long)):
                raise TypeError("'{}' must be of type integer".format(int_field))
        self.fields.append({
            'name': name,
            'field_type': field_type,
            'nuc_length': nuc_length,
            'nuc_offset': nuc_offset,
            'uc_length': uc_length,
            'uc_offset': uc_offset,
            'decimals': decimals,
            'type_description': type_description
        })

    def __repr__(self):
        return "<TypeDescription '{}' with {} fields (n/uclength={}/{})>".format(
            self.name, len(self.fields), self.nuc_length, self.uc_length
        )

class FunctionDescription(object):
    """ A function description

        This class wraps the RFC_FUNCTION_DESC_HANDLE as e.g. returned by
        RfcGetFunctionDesc() and used for server functionality.

        .. WARNING::

           Actually, the function description does not support exceptions
           (cf. RfcAddException() etc.)

        :param name: Name of the function.


        *Attributes and methods*

        **name**
          The name of the function.

        **parameters**
          The parameters as a list of dicts.

    """
    def __init__(self, name):
        self.name = name
        self.parameters = []

    def add_parameter(self, name, parameter_type, direction, nuc_length,
                      uc_length, decimals=0, default_value="", parameter_text="",
                      optional=False, type_description=None):
        """ Adds a parameter to the function description.

        :param name: Parameter name
        :type name: string (30)
        :param parameter_type: Type of the parameter
        :type parameter_type: string
        :param direction: Direction (RFC_IMPORT, RFC_EXPORT, RFC_CHANGING, RFC_TABLES)
        :type direction: string
        :param nuc_length: NUC length
        :type nuc_length: int
        :param uc_length: UC length
        :type uc_length: int
        :param decimals: Decimals (default=0)
        :type decimals: int
        :param default_value: Default value (default="")
        :type default_value: string (30)
        :param parameter_text: Parameter text (default="")
        :type parameter_text: string (79)
        :param optional: Is the parameter optional (default=False)
        :type optional: bool
        :param type_description: An object of class TypeDescription or None (default=None)
        :type type_description: object of class TypeDescription
        """
        if len(name)<1 or len(name)>30:
            raise TypeError("'name' (string) should be from 1-30 chars.")
        if parameter_type not in _type2rfc:
            raise TypeError("'parameter_type' (string) must be in [" + ", ".join(_type2rfc) + "]")
        if direction not in _direction2rfc:
            raise TypeError("'direction' (string) must be in [" + ", ".join(_direction2rfc) + "]")
        if len(default_value)>30:
            raise TypeError("'default_value' (string) must not exceed 30 chars.")
        if len(parameter_text)>79:
            raise TypeError("'parameter_text' (string) must not exceed 79 chars.")
        self.parameters.append({
            'name': name,
            'parameter_type': parameter_type,
            'direction': direction,
            'nuc_length': nuc_length,
            'uc_length': uc_length,
            'decimals': decimals,
            'default_value': default_value,
            'parameter_text': parameter_text,
            'optional': optional,
            'type_description': type_description
        })

    def __repr__(self):
        return "<FunctionDescription '{}' with {} params>".format(
            self.name, len(self.parameters)
        )

cdef RFC_UNIT_IDENTIFIER fillUnitIdentifier(unit) except *:
    cdef RFC_UNIT_IDENTIFIER uIdentifier
    cdef SAP_UC* sapuc
    uIdentifier.unitType = fillString(u"Q" if unit['queued'] else u"T")[0]
    if len(unit['id'] != RFC_UNITID_LN):
        raise RFCError("Invalid length of unit['id'] (should be {}, but found {}).".format(
            RFC_UNITID_LN, len(unit['id'])
        ))
    sapuc = fillString(unit['id'])
    strncpyU(uIdentifier.unitID, sapuc, RFC_UNITID_LN + 1)
    free(sapuc)
    return uIdentifier

################################################################################
# FILL FUNCTIONS                                                               #
################################################################################

cdef fillFunctionParameter(RFC_FUNCTION_DESC_HANDLE funcDesc, RFC_FUNCTION_HANDLE container, name, value):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_PARAMETER_DESC paramDesc
    cName = fillString(name)
    rc = RfcGetParameterDescByName(funcDesc, cName, &paramDesc, &errorInfo)
    free(cName)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    fillVariable(paramDesc.type, container, paramDesc.name, value, paramDesc.typeDescHandle)

cdef fillStructureField(RFC_TYPE_DESC_HANDLE typeDesc, RFC_STRUCTURE_HANDLE container, name, value):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_STRUCTURE_HANDLE struct
    cdef RFC_FIELD_DESC fieldDesc
    cdef SAP_UC* cName = fillString(name)
    rc = RfcGetFieldDescByName(typeDesc, cName, &fieldDesc, &errorInfo)
    free(cName)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    fillVariable(fieldDesc.type, container, fieldDesc.name, value, fieldDesc.typeDescHandle)

cdef fillTable(RFC_TYPE_DESC_HANDLE typeDesc, RFC_TABLE_HANDLE container, lines):
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_STRUCTURE_HANDLE lineHandle
    cdef unsigned int rowCount = int(len(lines))
    cdef unsigned int i = 0
    while i < rowCount:
        lineHandle = RfcAppendNewRow(container, &errorInfo)
        if not lineHandle:
            raise wrapError(&errorInfo)
        line = lines[i]
        # line = lines[0]
        if type(line) is dict:
            for name, value in line.iteritems():
                fillStructureField(typeDesc, lineHandle, name, value)
        else:
            fillStructureField(typeDesc, lineHandle, '', line)
        i += 1
        # https://stackoverflow.com/questions/33626623/the-most-efficient-way-to-remove-first-n-elements-in-a-list
        # del lines[:1]

cdef fillVariable(RFCTYPE typ, RFC_FUNCTION_HANDLE container, SAP_UC* cName, value, RFC_TYPE_DESC_HANDLE typeDesc):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_STRUCTURE_HANDLE struct
    cdef RFC_TABLE_HANDLE table
    cdef SAP_UC* cValue
    cdef SAP_RAW* bValue
    #print ("fill", wrapString(cName), value)
    try:
        if typ == RFCTYPE_STRUCTURE:
            if type(value) is not dict:
               raise TypeError('dictionary required for structure parameter, received', str(type(value)))
            rc = RfcGetStructure(container, cName, &struct, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            for name, value in value.iteritems():
                fillStructureField(typeDesc, struct, name, value)
        elif typ == RFCTYPE_TABLE:
            if type(value) is not list:
               raise TypeError('list required for table parameter, received', str(type(value)))
            rc = RfcGetTable(container, cName, &table, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            fillTable(typeDesc, table, value)
        elif typ == RFCTYPE_BYTE:
            bValue = fillBytes(value)
            rc = RfcSetBytes(container, cName, bValue, int(len(value)), &errorInfo)
            free(bValue)
        elif typ == RFCTYPE_XSTRING:
            bValue = fillBytes(value)
            rc = RfcSetXString(container, cName, bValue, int(len(value)), &errorInfo)
            free(bValue)
        elif typ == RFCTYPE_CHAR:
            if type(value) is not str and type(value) is not unicode:
                raise TypeError('an string is required, received', value, 'of type', type(value))
            cValue = fillString(value)
            rc = RfcSetChars(container, cName, cValue, strlenU(cValue), &errorInfo)
            free(cValue)
        elif typ == RFCTYPE_STRING:
            if type(value) is not str and type(value) is not unicode:
                raise TypeError('an string is required, received', value, 'of type', type(value))
            cValue = fillString(value)
            rc = RfcSetString(container, cName, cValue, strlenU(cValue), &errorInfo)
            free(cValue)
        elif typ == RFCTYPE_NUM:
            try:
                if value.isdigit():
                    cValue = fillString(value)
                    rc = RfcSetNum(container, cName, cValue, strlenU(cValue), &errorInfo)
                    free(cValue)
                else:
                    raise
            except:
                raise TypeError('a numeric string is required, received', value, 'of type', type(value))
        elif typ == RFCTYPE_BCD or typ == RFCTYPE_FLOAT or typ == RFCTYPE_DECF16 or typ == RFCTYPE_DECF34:
            # cast to string prevents rounding errors in NWRFC SDK
            try:
                if type(value) is float or type(value) is Decimal:
                    # locale correct float representation
                    svalue = locale.str(value)
                else:
                    # string passed from application should be locale correct, do nothing
                    svalue = value
                    # decimal separator must be "." for the Decimal parsing check
                    locale_radix = locale.nl_langinfo(locale.RADIXCHAR)
                    if locale_radix != ".":
                        Decimal(value.replace(locale_radix, '.'))
                    else:
                        Decimal(value)
                cValue = fillString(svalue)
            except:
                raise TypeError('a decimal value required, received', value, 'of type', type(value))
            rc = RfcSetString(container, cName, cValue, strlenU(cValue), &errorInfo)
            free(cValue)
        elif typ in (RFCTYPE_INT, RFCTYPE_INT1, RFCTYPE_INT2):
            if type(value) is not int:
                raise TypeError('an integer required, received', value, 'of type', type(value))
            rc = RfcSetInt(container, cName, value, &errorInfo)
        elif typ == RFCTYPE_INT8:
            if type(value) is not int:
                raise TypeError('an integer required, received', value, 'of type', type(value))
            rc = RfcSetInt8(container, cName, value, &errorInfo)
        elif typ == RFCTYPE_DATE:
            if value:
                format_ok = True
                if type(value) is datetime.date:
                    cValue = fillString('{:04d}{:02d}{:02d}'.format(value.year, value.month, value.day))
                else:
                    try:
                        if len(value) != 8:
                            format_ok = False
                        else:
                            if len(value.rstrip()) > 0:
                                datetime.date(int(value[:4]), int(value[4:6]), int(value[6:8]))
                            cValue = fillString(value)
                    except:
                        format_ok = False
                if not format_ok:
                    raise TypeError('date value required, received', value, 'of type', type(value))
                rc = RfcSetDate(container, cName, cValue, &errorInfo)
                free(cValue)
            else:
                rc = RFC_OK
        elif typ == RFCTYPE_TIME:
            if value:
                format_ok = True
                if type(value) is datetime.time:
                    cValue = fillString('{:02d}{:02d}{:02d}'.format(value.hour, value.minute, value.second))
                else:
                    try:
                        if len(value) != 6:
                            format_ok = False
                        else:
                            if len(value.rstrip()) > 0:
                                datetime.time(int(value[:2]), int(value[2:4]), int(value[4:6]))
                            cValue = fillString(value)
                    except:
                        format_ok = False

                if not format_ok:
                    raise TypeError('time value required, received', value, 'of type', type(value))
                rc = RfcSetTime(container, cName, cValue, &errorInfo)
                free(cValue)
            else:
                rc = RFC_OK
        else:
            raise RFCError('Unknown RFC type %d when filling %s' % (typ, wrapString(cName)))
    except TypeError as e:
        # This way the field name will be attached in reverse direction
        # to the argument list of the exception. This helps users to find
        # mistakes easier in complex mapping scenarios.
        e.args += (wrapString(cName), )
        raise
    if rc != RFC_OK:
        raise wrapError(&errorInfo)

cdef SAP_RAW* fillBytes(pystr) except NULL:
    cdef size_t size = len(pystr)
    cdef SAP_RAW* bytes = <SAP_RAW*> malloc(size)
    memcpy(bytes, <char*> pystr, size)
    return bytes

cdef fillError(exception, RFC_ERROR_INFO* errorInfo):
    group2error = { ABAPApplicationError: ABAP_APPLICATION_FAILURE,
                    ABAPRuntimeError: ABAP_RUNTIME_FAILURE,
                    LogonError: LOGON_FAILURE,
                    CommunicationError: COMMUNICATION_FAILURE,
                    ExternalRuntimeError: EXTERNAL_RUNTIME_FAILURE,
                    ExternalApplicationError: EXTERNAL_APPLICATION_FAILURE,
                    ExternalAuthorizationError: EXTERNAL_AUTHORIZATION_FAILURE
    }
    if type(exception) not in group2error:
        raise RFCError("Not a valid error group.")

    errorInfo.group = group2error.get(type(exception))

    if exception.message: # fixed length, exactly 512 chars
        #str = exception.message[0:512].ljust(512)
        str = exception.message[0:512]
        sapuc = fillString(str)
        strncpyU(errorInfo.message, sapuc, min(len(str)+1, 512))
        free(sapuc)
    errorInfo.code = exception.code if exception.code else RFC_UNKNOWN_ERROR
    if exception.key: # fixed length, exactly 128 chars
        str = exception.key[0:128]
        sapuc = fillString(str)
        strncpyU(errorInfo.key, sapuc, min(len(str)+1,128))
        free(sapuc)
    if exception.msg_class:
        sapuc = fillString(exception.msg_class[0:20])
        strncpyU(errorInfo.abapMsgClass, sapuc, len(exception.msg_class[0:20]) + 1)
        free(sapuc)
    if exception.msg_type:
        sapuc = fillString(exception.msg_type[0:1])
        strncpyU(errorInfo.abapMsgType, sapuc, len(exception.msg_type[0:1]) + 1)
        free(sapuc)
    if exception.msg_number:
        sapuc = fillString(exception.msg_number[0:3])
        strncpyU(errorInfo.abapMsgNumber, sapuc, len(exception.msg_number[0:3]) + 1)
        free(sapuc)
    if exception.msg_v1:
        sapuc = fillString(exception.msg_v1[0:50])
        strncpyU(errorInfo.abapMsgV1, sapuc, len(exception.msg_v1[0:50]) + 1)
        free(sapuc)
    if exception.msg_v2:
        sapuc = fillString(exception.msg_v2[0:50])
        strncpyU(errorInfo.abapMsgV2, sapuc, len(exception.msg_v2[0:50]) + 1)
        free(sapuc)
    if exception.msg_v3:
        sapuc = fillString(exception.msg_v3[0:50])
        strncpyU(errorInfo.abapMsgV3, sapuc, len(exception.msg_v3[0:50]) + 1)
        free(sapuc)
    if exception.msg_v4:
        sapuc = fillString(exception.msg_v4[0:50])
        strncpyU(errorInfo.abapMsgV4, sapuc, len(exception.msg_v4[0:50]) + 1)
        free(sapuc)

cdef SAP_UC* fillString(pyuc) except NULL:
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    ucbytes = pyuc.encode('utf-8')
    cdef unsigned ucbytes_len = int(len(ucbytes))
    cdef unsigned sapuc_size = ucbytes_len + 1
    cdef SAP_UC* sapuc = mallocU(sapuc_size)
    sapuc[0] = '\0'
    cdef unsigned result_len = 0
    rc = RfcUTF8ToSAPUC(ucbytes, ucbytes_len, sapuc, &sapuc_size, &result_len, &errorInfo)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    return sapuc

################################################################################
# WRAPPER FUNCTIONS                                                            #
################################################################################
# wrapper functions take C values and returns Python values

cdef wrapConnectionAttributes(RFC_ATTRIBUTES attributes, rstrip=True):
    return {
          'dest': wrapString(attributes.dest, 64, rstrip)                                     # RFC destination
        , 'host': wrapString(attributes.host, 100, rstrip)                                    # Own host name
        , 'partnerHost': wrapString(attributes.partnerHost, 100, rstrip)                      # Partner host name
        , 'sysNumber': wrapString(attributes.sysNumber, 2, rstrip)                            # R/3 system number
        , 'sysId': wrapString(attributes.sysId, 8, rstrip)                                    # R/3 system ID
        , 'client': wrapString(attributes.client, 3, rstrip)                                  # Client ("Mandant")
        , 'user': wrapString(attributes.user, 12, rstrip)                                     # User
        , 'language': wrapString(attributes.language, 2, rstrip)                              # Language
        , 'trace': wrapString(attributes.trace, 1, rstrip)                                    # Trace level (0-3)
        , 'isoLanguage': wrapString(attributes.isoLanguage, 2, rstrip)                        # 2-byte ISO-Language
        , 'codepage': wrapString(attributes.codepage, 4, rstrip)                              # Own code page
        , 'partnerCodepage': wrapString(attributes.partnerCodepage, 4, rstrip)                # Partner code page
        , 'rfcRole': wrapString(attributes.rfcRole, 1, rstrip)                                # C/S: RFC Client / RFC Server
        , 'type': wrapString(attributes.type, 1)                                              # 2/3/E/R: R/2,R/3,Ext,Reg.Ext
        , 'partnerType': wrapString(attributes.partnerType, 1)                                # 2/3/E/R: R/2,R/3,Ext,Reg.Ext
        , 'rel': wrapString(attributes.rel, 4, rstrip)                                        # My system release
        , 'partnerRel': wrapString(attributes.partnerRel, 4, rstrip)                          # Partner system release
        , 'kernelRel': wrapString(attributes.kernelRel, 4, rstrip)                            # Partner kernel release
        , 'cpicConvId': wrapString(attributes.cpicConvId, 8, rstrip)                          # CPI-C Conversation ID
        , 'progName': wrapString(attributes.progName, 128, rstrip)                            # Name of the calling APAB program (report, module pool)
        , 'partnerBytesPerChar': wrapString(attributes.partnerBytesPerChar, 1, rstrip)        # Number of bytes per character in the backend's current codepage. Note this is different from the semantics of the PCS parameter.
        , 'partnerSystemCodepage': wrapString(attributes.partnerSystemCodepage, 4, rstrip)    #  Partner system code page
        # , 'reserved': wrapString(attributes.reserved, 78, rstrip)                             # Reserved for later use
 }


cdef wrapTypeDescription(RFC_TYPE_DESC_HANDLE typeDesc):
    """ Parses a RFC_TYPE_DESC_HANDLE

    :param typeDesc: Handle of RFC_TYPE_DESC_HANDLE
    :return: object of class TypeDescription
    """
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_FIELD_DESC fieldDesc
    cdef RFC_ABAP_NAME typeName
    cdef unsigned nuc_length, uc_length
    cdef unsigned i, fieldCount

    rc = RfcGetTypeName(typeDesc, typeName, &errorInfo)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    name = wrapString(typeName)
    rc = RfcGetTypeLength(typeDesc, &nuc_length, &uc_length, &errorInfo)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    type_desc = TypeDescription(name, nuc_length, uc_length)

    rc = RfcGetFieldCount(typeDesc, &fieldCount, &errorInfo)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    for i in range(fieldCount):
        rc = RfcGetFieldDescByIndex(typeDesc, i, &fieldDesc, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        field_description = {
            'name': wrapString(fieldDesc.name),
            'field_type': wrapString(<SAP_UC*>RfcGetTypeAsString(fieldDesc.type)),
            'nuc_length': fieldDesc.nucLength,
            'nuc_offset': fieldDesc.nucOffset,
            'uc_length': fieldDesc.ucLength,
            'uc_offset': fieldDesc.ucOffset,
            'decimals': fieldDesc.decimals
        }
        if fieldDesc.typeDescHandle is NULL:
            field_description['type_description'] = None
        else:
            field_description['type_description'] = wrapTypeDescription(fieldDesc.typeDescHandle)
        # Add field to object
        type_desc.add_field(**field_description)

    return type_desc

cdef wrapFunctionDescription(RFC_FUNCTION_DESC_HANDLE funcDesc):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_ABAP_NAME functionName
    cdef unsigned i, paramCount
    cdef RFC_PARAMETER_DESC paramDesc

    rc = RfcGetFunctionName(funcDesc, functionName, &errorInfo)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    name = wrapString(functionName)
    func_desc = FunctionDescription(name)

    rc = RfcGetParameterCount(funcDesc, &paramCount, &errorInfo)
    if rc != RFC_OK:
        raise wrapError(&errorInfo)
    for i in range(paramCount):
        rc = RfcGetParameterDescByIndex(funcDesc, i, &paramDesc, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        parameter_description = {
            'name': wrapString(paramDesc.name),
            'parameter_type': wrapString(<SAP_UC*>RfcGetTypeAsString(paramDesc.type)),
            'direction': wrapString(<SAP_UC*>RfcGetDirectionAsString(paramDesc.direction)),
            'nuc_length': paramDesc.nucLength,
            'uc_length': paramDesc.ucLength,
            'decimals': paramDesc.decimals,
            'default_value': wrapString(paramDesc.defaultValue),
            'parameter_text': wrapString(paramDesc.parameterText),
            'optional': bool(paramDesc.optional)
            # skip: void* extendedDescription;	///< This field can be used by the application programmer (i.e. you) to store arbitrary extra information.
        }
        if paramDesc.typeDescHandle is NULL:
            parameter_description['type_description'] = None
        else:
            parameter_description['type_description'] = wrapTypeDescription(paramDesc.typeDescHandle)
        func_desc.add_parameter(**parameter_description)

    return func_desc


cdef wrapResult(RFC_FUNCTION_DESC_HANDLE funcDesc, RFC_FUNCTION_HANDLE container, RFC_DIRECTION filter_parameter_direction, config):
    """
    :param funcDesc: a C pointer to a function description.
    :param container: a C pointer to a function container
    :param filter_parameter_direction: A RFC_DIRECTION - parameters with this
           direction will be excluded.
    :param config (rstrip: right strip strings, dtime: return datetime objects)
    :return:
    """
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef unsigned i, paramCount
    cdef RFC_PARAMETER_DESC paramDesc
    RfcGetParameterCount(funcDesc, &paramCount, NULL)
    result = {}
    for i in range(paramCount):
        RfcGetParameterDescByIndex(funcDesc, i, &paramDesc, NULL)
        if paramDesc.direction != filter_parameter_direction:
            result[wrapString(paramDesc.name)] = wrapVariable(paramDesc.type, container, paramDesc.name, paramDesc.nucLength, paramDesc.typeDescHandle, config)
    return result

cdef wrapUnitIdentifier(RFC_UNIT_IDENTIFIER uIdentifier):
    return {
        'queued': u"Q" == wrapString(&uIdentifier.unitType, 1),
        'id': wrapString(uIdentifier.unitID)
    }

cdef wrapStructure(RFC_TYPE_DESC_HANDLE typeDesc, RFC_STRUCTURE_HANDLE container, config):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef unsigned i, fieldCount
    cdef RFC_FIELD_DESC fieldDesc
    RfcGetFieldCount(typeDesc, &fieldCount, NULL)
    result = {}
    for i in range(fieldCount):
        RfcGetFieldDescByIndex(typeDesc, i, &fieldDesc, NULL)
        result[wrapString(fieldDesc.name)] = wrapVariable(fieldDesc.type, container, fieldDesc.name, fieldDesc.nucLength, fieldDesc.typeDescHandle, config)
    if len(result) == 1:
        if '' in result:
            result = result['']
    return result

## Used for debugging tables, cf. wrapTable()
#cdef class TableCursor:
#
#    cdef RFC_TYPE_DESC_HANDLE typeDesc
#    cdef RFC_TABLE_HANDLE container
#
#    def __getitem__(self, i):
#        cdef RFC_ERROR_INFO errorInfo
#        RfcMoveTo(self.container, i, &errorInfo)
#        return wrapStructure(self.typeDesc, self.container)

cdef wrapTable(RFC_TYPE_DESC_HANDLE typeDesc, RFC_TABLE_HANDLE container, config):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef unsigned rowCount
    # # For debugging in tables (cf. class TableCursor)
    # tc = TableCursor()
    # tc.typeDesc = typeDesc
    # tc.container = container
    # return tc
    RfcGetRowCount(container, &rowCount, &errorInfo)
    table = [None] * rowCount
    while rowCount > 0:
        rowCount -= 1
        RfcMoveTo(container, rowCount, &errorInfo)
        table[rowCount] = wrapStructure(typeDesc, container, config)
        RfcDeleteCurrentRow(container, &errorInfo)
    return table

cdef wrapVariable(RFCTYPE typ, RFC_FUNCTION_HANDLE container, SAP_UC* cName, unsigned cLen, RFC_TYPE_DESC_HANDLE typeDesc, config):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    cdef RFC_STRUCTURE_HANDLE structure
    cdef RFC_TABLE_HANDLE table
    cdef RFC_CHAR* charValue
    cdef SAP_UC* stringValue
    cdef RFC_NUM* numValue
    cdef SAP_RAW* byteValue
    cdef RFC_FLOAT floatValue
    cdef RFC_INT intValue
    cdef RFC_INT1 int1Value
    cdef RFC_INT2 int2Value
    cdef RFC_INT8 int8Value
    cdef RFC_DATE dateValue
    cdef RFC_TIME timeValue
    cdef unsigned resultLen, strLen
    if typ == RFCTYPE_STRUCTURE:
        rc = RfcGetStructure(container, cName, &structure, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return wrapStructure(typeDesc, structure, config)
    elif typ == RFCTYPE_TABLE:
        rc = RfcGetTable(container, cName, &table, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return wrapTable(typeDesc, table, config)
    elif typ == RFCTYPE_CHAR:
        charValue = mallocU(cLen)
        try:
            rc = RfcGetChars(container, cName, charValue, cLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return wrapString(charValue, cLen, config & _MASK_RSTRIP)
        finally:
            free(charValue)
    elif typ == RFCTYPE_STRING:
        rc = RfcGetStringLength(container, cName, &strLen, &errorInfo)
        try:
            stringValue = mallocU(strLen+1)
            rc = RfcGetString(container, cName, stringValue, strLen+1, &resultLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return wrapString(stringValue, resultLen)
        finally:
            free(stringValue)
    elif typ == RFCTYPE_NUM:
        numValue = mallocU(cLen)
        try:
            rc = RfcGetNum(container, cName, numValue, cLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return wrapString(numValue, cLen)
        finally:
            free(numValue)
    elif typ == RFCTYPE_BYTE:
        byteValue = <SAP_RAW*> malloc(cLen)
        try:
            rc = RfcGetBytes(container, cName, byteValue, cLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return byteValue[:cLen]
        finally:
            free(byteValue)
    elif typ == RFCTYPE_XSTRING:
        rc = RfcGetStringLength(container, cName, &strLen, &errorInfo)
        try:
            byteValue = <SAP_RAW*> malloc(strLen+1)
            byteValue[strLen] = '\0'
            rc = RfcGetXString(container, cName, byteValue, strLen, &resultLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return byteValue[:resultLen]
        finally:
            free(byteValue)
    elif typ == RFCTYPE_BCD:
        # An upper bound for the length of the _string representation_
        # of the BCD is given by (2*cLen)-1 (each digit is encoded in 4bit,
        # the first 4 bit are reserved for the sign)
        # Furthermore, a sign char, a decimal separator char may be present
        # => (2*cLen)+1
        strLen = 2*cLen + 1
        try:
            stringValue = mallocU(strLen+1)
            rc = RfcGetString(container, cName, stringValue, strLen+1, &resultLen, &errorInfo)
            if rc == 23: # Buffer too small, use returned requried result length
                #print("Warning: Buffer for BCD (cLen={}, buffer={}) too small: "
                #      "trying with {}".format(cLen, strLen, resultLen))
                free(stringValue)
                strLen = resultLen
                stringValue = mallocU(strLen+1)
                rc = RfcGetString(container, cName, stringValue, strLen+1, &resultLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return Decimal(wrapString(stringValue, -1, config & _MASK_RSTRIP))
        finally:
            free(stringValue)
    elif typ == RFCTYPE_DECF16 or typ == RFCTYPE_DECF34:
        # An upper bound for the length of the _string representation_
        # of the DECF is given by (2*cLen)-1 (each digit is encoded in 4bit,
        # the first 4 bit are reserved for the sign)
        # Furthermore, a sign char, a decimal separator char may be present
        # => (2*cLen)+1
        # and exponent char, sign and exponent
        # => +9
        strLen = 2*cLen + 10
        try:
            stringValue = mallocU(strLen+1)
            rc = RfcGetString(container, cName, stringValue, strLen+1, &resultLen, &errorInfo)
            if rc == 23: # Buffer too small, use returned requried result length
                #print("Warning: Buffer for DECF (cLen={}, buffer={}) too small: "
                #      "trying with {}".format(cLen, strLen, resultLen))
                free(stringValue)
                strLen = resultLen
                stringValue = mallocU(strLen+1)
                rc = RfcGetString(container, cName, stringValue, strLen+1, &resultLen, &errorInfo)
            if rc != RFC_OK:
                raise wrapError(&errorInfo)
            return Decimal(wrapString(stringValue, -1, config & _MASK_RSTRIP))
        finally:
            free(stringValue)
    elif typ == RFCTYPE_FLOAT:
        rc = RfcGetFloat(container, cName, &floatValue, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return floatValue
    elif typ == RFCTYPE_INT:
        rc = RfcGetInt(container, cName, &intValue, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return intValue
    elif typ == RFCTYPE_INT1:
        rc = RfcGetInt1(container, cName, &int1Value, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return int1Value
    elif typ == RFCTYPE_INT2:
        rc = RfcGetInt2(container, cName, &int2Value, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return int2Value
    elif typ == RFCTYPE_INT8:
        rc = RfcGetInt8(container, cName, &int8Value, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        return int8Value
    elif typ == RFCTYPE_DATE:
        rc = RfcGetDate(container, cName, dateValue, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        value = wrapString(dateValue, 8)
        # return date or None
        if config & _MASK_DTIME:
            if (value == '00000000') or not value:
                return None
            return datetime.datetime.strptime(value, '%Y%m%d').date()
        # return date string or ''
        if (value == '00000000') or not value:
              return ''
        return value
    elif typ == RFCTYPE_TIME:
        rc = RfcGetTime(container, cName, timeValue, &errorInfo)
        if rc != RFC_OK:
            raise wrapError(&errorInfo)
        value = wrapString(timeValue, 6)
        # return time or None
        if config & _MASK_DTIME:
            if not value:
                return None
            return datetime.datetime.strptime(value, '%H%M%S').time()
        # return time string or ''
        if not value:
            return ''
        return value
    else:
        raise RFCError('Unknown RFC type %d when wrapping %s' % (typ, wrapString(cName)))

cdef wrapError(RFC_ERROR_INFO* errorInfo):
    group2error = { ABAP_APPLICATION_FAILURE: ABAPApplicationError,
                    ABAP_RUNTIME_FAILURE: ABAPRuntimeError,
                    LOGON_FAILURE: LogonError,
                    COMMUNICATION_FAILURE: CommunicationError,
                    EXTERNAL_RUNTIME_FAILURE: ExternalRuntimeError,
                    EXTERNAL_APPLICATION_FAILURE: ExternalApplicationError,
                    EXTERNAL_AUTHORIZATION_FAILURE: ExternalAuthorizationError
    }
    error = group2error[errorInfo.group]
    return error(wrapString(errorInfo.message), errorInfo.code, wrapString(errorInfo.key),
        wrapString(errorInfo.abapMsgClass), wrapString(errorInfo.abapMsgType), wrapString(errorInfo.abapMsgNumber),
        wrapString(errorInfo.abapMsgV1), wrapString(errorInfo.abapMsgV2),
        wrapString(errorInfo.abapMsgV3), wrapString(errorInfo.abapMsgV4))

cdef wrapString(SAP_UC* uc, uclen=-1, rstrip=False):
    cdef RFC_RC rc
    cdef RFC_ERROR_INFO errorInfo
    if uclen == -1:
        uclen = strlenU(uc)
    if uclen == 0:
        return ''
    cdef unsigned utf8_size = uclen * 3 + 1
    cdef char *utf8 = <char*> malloc(utf8_size)
    utf8[0] = '\0'
    cdef unsigned result_len = 0
    rc = RfcSAPUCToUTF8(uc, uclen, <RFC_BYTE*> utf8, &utf8_size, &result_len, &errorInfo)
    if rc != RFC_OK:
        # raise wrapError(&errorInfo)
        raise RFCError('wrapString uclen: %u utf8_size: %u' % (uclen, utf8_size))
    try:
        if rstrip:
            return utf8.rstrip().decode('UTF-8')
        else:
            return utf8.decode('UTF-8')
    finally:
        free(utf8)
