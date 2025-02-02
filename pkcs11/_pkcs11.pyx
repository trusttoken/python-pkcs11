#!python
#cython: language_level=3
"""
High-level Python PKCS#11 Wrapper.

Most class here inherit from pkcs11.types, which provides easier introspection
for Sphinx/Jedi/etc, as this module is not importable without having the
library loaded.
"""

from __future__ import (absolute_import, unicode_literals,
                        print_function, division)

from cython.view cimport array
from cpython.mem cimport PyMem_Malloc, PyMem_Free

IF UNAME_SYSNAME == "Windows":
    from . cimport _mswin as mswin
ELSE:
    from posix cimport dlfcn

from ._pkcs11_defn cimport *
include '_errors.pyx'
include '_utils.pyx'

from . import types
from .defaults import *
from .exceptions import *
from .constants import *
from .mechanisms import *
from .types import (
    _CK_UTF8CHAR_to_str,
    _CK_VERSION_to_tuple,
    _CK_MECHANISM_TYPE_to_enum,
)


# _funclist is used to keep the pointer to the list of functions, when lib() is invoked.
# This is a global, as this object cannot be shared between Python and Cython classes
# Due to this limitation, the current implementation limits the loading of the library
# to one instance only, or to several instances of the same kind.
cdef CK_FUNCTION_LIST *_funclist = NULL


cdef class AttributeList:
    """
    A list of CK_ATTRIBUTE objects.
    """

    cdef CK_ATTRIBUTE *data
    """CK_ATTRIBUTE * representation of the data."""
    cdef CK_ULONG count
    """Length of `data`."""

    cdef _values

    def __cinit__(self, attrs):
        attrs = dict(attrs)
        self.count = count = <CK_ULONG> len(attrs)

        self.data = <CK_ATTRIBUTE *> PyMem_Malloc(count * sizeof(CK_ATTRIBUTE))
        if not self.data:
            raise MemoryError()

        # Turn the values into bytes and store them so we have pointers
        # to them.
        self._values = [
            (key, _pack_attribute(key, value))
            for key, value in attrs.items()
        ]

        for index, (key, value) in enumerate(self._values):
            self.data[index].type = key
            self.data[index].pValue = <CK_CHAR *> value
            self.data[index].ulValueLen = <CK_ULONG>len(value)

    def __dealloc__(self):
        PyMem_Free(self.data)


cdef class MechanismWithParam:
    """
    Python wrapper for a Mechanism with its parameter
    """

    cdef CK_MECHANISM *data
    """The mechanism."""
    cdef void *param
    """Reference to a pointer we might need to free."""

    def __cinit__(self, *args):
        self.data = <CK_MECHANISM *> PyMem_Malloc(sizeof(CK_MECHANISM))
        self.param = NULL

    def __init__(self, key_type, mapping, mechanism=None, param=None):
        if mechanism is None:
            try:
                mechanism = mapping[key_type]
            except KeyError:
                raise ArgumentsBad("No default mechanism for this key type. "
                                    "Please specify `mechanism`.")

        if not isinstance(mechanism, Mechanism):
            raise ArgumentsBad("`mechanism` must be a Mechanism.")
        # Possible types of parameters we might need to allocate
        # These are used to make assigning to the object we malloc() easier
        # FIXME: is there a better way to do this?
        cdef CK_RSA_PKCS_OAEP_PARAMS *oaep_params
        cdef CK_RSA_PKCS_PSS_PARAMS *pss_params
        cdef CK_ECDH1_DERIVE_PARAMS *ecdh1_params

        # Unpack mechanism parameters
        if mechanism is Mechanism.RSA_PKCS_OAEP:
            paramlen = sizeof(CK_RSA_PKCS_OAEP_PARAMS)
            self.param = oaep_params = \
                <CK_RSA_PKCS_OAEP_PARAMS *> PyMem_Malloc(paramlen)

            oaep_params.source = CKZ_DATA_SPECIFIED

            if param is None:
                param = DEFAULT_MECHANISM_PARAMS[mechanism]

            (oaep_params.hashAlg, oaep_params.mgf, source_data) = param

            if source_data is None:
                oaep_params.pSourceData = NULL
                oaep_params.ulSourceDataLen = 0
            else:
                oaep_params.pSourceData = <CK_BYTE *> source_data
                oaep_params.ulSourceDataLen = <CK_ULONG> len(source_data)

        elif mechanism in (Mechanism.RSA_PKCS_PSS,
                           Mechanism.SHA1_RSA_PKCS_PSS,
                           Mechanism.SHA224_RSA_PKCS_PSS,
                           Mechanism.SHA256_RSA_PKCS_PSS,
                           Mechanism.SHA384_RSA_PKCS_PSS,
                           Mechanism.SHA512_RSA_PKCS_PSS):
            paramlen = sizeof(CK_RSA_PKCS_PSS_PARAMS)
            self.param = pss_params = \
                <CK_RSA_PKCS_PSS_PARAMS *> PyMem_Malloc(paramlen)

            if param is None:
                # All PSS mechanisms have the same defaults
                param = DEFAULT_MECHANISM_PARAMS[Mechanism.RSA_PKCS_PSS]

            (pss_params.hashAlg, pss_params.mgf, pss_params.sLen) = param

        elif mechanism is Mechanism.ECDH1_DERIVE:
            paramlen = sizeof(CK_ECDH1_DERIVE_PARAMS)
            self.param = ecdh1_params = \
                <CK_ECDH1_DERIVE_PARAMS *> PyMem_Malloc(paramlen)

            (ecdh1_params.kdf, shared_data, public_data) = param

            if shared_data is None:
                ecdh1_params.pSharedData = NULL
                ecdh1_params.ulSharedDataLen = 0
            else:
                ecdh1_params.pSharedData = shared_data
                ecdh1_params.ulSharedDataLen = <CK_ULONG> len(shared_data)

            ecdh1_params.pPublicData = public_data
            ecdh1_params.ulPublicDataLen = <CK_ULONG> len(public_data)

        elif isinstance(param, bytes):
            self.data.pParameter = <CK_BYTE *> param
            paramlen = len(param)

        elif param is None:
            self.data.pParameter = NULL
            paramlen = 0

        else:
            raise ArgumentsBad("Unexpected argument to mechanism_param")

        self.data.mechanism = mechanism
        self.data.ulParameterLen = <CK_ULONG> paramlen

        if self.param != NULL:
            self.data.pParameter = self.param

    def __dealloc__(self):
        PyMem_Free(self.data)
        PyMem_Free(self.param)


class Slot(types.Slot):
    """Extend Slot with implementation."""

    def get_token(self):
        cdef CK_TOKEN_INFO info

        assertRV(_funclist.C_GetTokenInfo(self.slot_id, &info))

        _fix_string_length(info.label, sizeof(info.label))
        _fix_string_length(info.serialNumber, sizeof(info.serialNumber))
        _fix_string_length(info.manufacturerID, sizeof(info.manufacturerID))
        _fix_string_length(info.model, sizeof(info.model))

        return Token(self, **info)

    def get_mechanisms(self):
        cdef CK_ULONG count

        assertRV(_funclist.C_GetMechanismList(self.slot_id, NULL, &count))

        if count == 0:
            return set()

        cdef CK_MECHANISM_TYPE [:] mechanisms = CK_ULONG_buffer(count)

        assertRV(_funclist.C_GetMechanismList(self.slot_id, &mechanisms[0], &count))

        return set(map(_CK_MECHANISM_TYPE_to_enum, mechanisms))

    def get_mechanism_info(self, mechanism):
        cdef CK_MECHANISM_INFO info

        assertRV(_funclist.C_GetMechanismInfo(self.slot_id, mechanism, &info))

        return types.MechanismInfo(self, mechanism, **info)


class Token(types.Token):
    """Extend Token with implementation."""

    def open(self, rw=False, user_pin=None, so_pin=None):
        cdef CK_SESSION_HANDLE handle
        cdef CK_FLAGS flags = CKF_SERIAL_SESSION
        cdef CK_USER_TYPE user_type

        if rw:
            flags |= CKF_RW_SESSION

        if user_pin is not None and so_pin is not None:
            raise ArgumentsBad("Set either `user_pin` or `so_pin`")
        elif user_pin is not None:
            pin = user_pin.encode('utf-8')
            user_type = CKU_USER
        elif so_pin is not None:
            pin = so_pin.encode('utf-8')
            user_type = CKU_SO
        else:
            pin = None
            user_type = UserType.NOBODY

        assertRV(_funclist.C_OpenSession(self.slot.slot_id, flags, NULL, NULL, &handle))

        if pin is not None:
            assertRV(_funclist.C_Login(handle, user_type, pin, <CK_ULONG> len(pin)))

        return Session(self, handle, rw=rw, user_type=user_type)


class SearchIter:
    """Iterate a search for objects on a session."""

    def __init__(self, session, attrs):
        self.session = session

        template = AttributeList(attrs)
        self.session._operation_lock.acquire()
        self._active = True
        assertRV(_funclist.C_FindObjectsInit(self.session._handle,
                                   template.data, template.count))

    def __iter__(self):
        return self

    def __next__(self):
        """Get the next object."""
        cdef CK_OBJECT_HANDLE handle
        cdef CK_ULONG count

        assertRV(_funclist.C_FindObjects(self.session._handle,
                               &handle, 1, &count))

        if count == 0:
            self._finalize()
            raise StopIteration()
        else:
            return Object._make(self.session, handle)

    def __del__(self):
        """Close the search."""
        self._finalize()

    def _finalize(self):
        """Finish the operation."""
        if self._active:
            self._active = False
            assertRV(_funclist.C_FindObjectsFinal(self.session._handle))
            self.session._operation_lock.release()


def merge_templates(default_template, *user_templates):
    template = default_template.copy()

    for user_template in user_templates:
        if user_template is not None:
            template.update(user_template)

    return {
        key: value
        for key, value in template.items()
        if value is not DEFAULT
    }


class Session(types.Session):
    """Extend Session with implementation."""

    def close(self):
        if self.user_type != UserType.NOBODY:
            assertRV(_funclist.C_Logout(self._handle))

        assertRV(_funclist.C_CloseSession(self._handle))

    def get_objects(self, attrs=None):
        return SearchIter(self, attrs or {})

    def create_object(self, attrs):
        cdef CK_OBJECT_HANDLE new

        template = AttributeList(attrs)
        assertRV(_funclist.C_CreateObject(self._handle,
                                template.data, template.count,
                                &new))

        return Object._make(self, new)

    def create_domain_parameters(self, key_type, attrs,
                                 local=False, store=False):
        if local and store:
            raise ArgumentsBad("Cannot set both `local` and `store`")

        attrs = dict(attrs)
        attrs[Attribute.CLASS] = ObjectClass.DOMAIN_PARAMETERS
        attrs[Attribute.KEY_TYPE] = key_type
        attrs[Attribute.TOKEN] = store

        if local:
            return DomainParameters(self, None, attrs)
        else:
            return self.create_object(attrs)

    def generate_domain_parameters(self, key_type, param_length, store=False,
                                   mechanism=None, mechanism_param=None,
                                   template=None):
        if not isinstance(key_type, KeyType):
            raise ArgumentsBad("`key_type` must be KeyType.")

        if not isinstance(param_length, int):
            raise ArgumentsBad("`param_length` is the length in bits.")

        mech = MechanismWithParam(
            key_type, DEFAULT_PARAM_GENERATE_MECHANISMS,
            mechanism, mechanism_param)

        template_ = {
            Attribute.CLASS: ObjectClass.DOMAIN_PARAMETERS,
            Attribute.TOKEN: store,
            Attribute.PRIME_BITS: param_length,
        }
        attrs = AttributeList(merge_templates(template_, template))

        cdef CK_OBJECT_HANDLE obj

        assertRV(_funclist.C_GenerateKey(self._handle,
                               mech.data,
                               attrs.data, attrs.count,
                               &obj))

        return Object._make(self, obj)

    def generate_key(self, key_type, key_length=None,
                     id=None, label=None,
                     store=False, capabilities=None,
                     mechanism=None, mechanism_param=None,
                     template=None):

        if not isinstance(key_type, KeyType):
            raise ArgumentsBad("`key_type` must be KeyType.")

        if key_length is not None and not isinstance(key_length, int):
            raise ArgumentsBad("`key_length` is the length in bits.")

        if capabilities is None:
            try:
                capabilities = DEFAULT_KEY_CAPABILITIES[key_type]
            except KeyError:
                raise ArgumentsBad("No default capabilities for this key "
                                   "type. Please specify `capabilities`.")

        mech = MechanismWithParam(
            key_type, DEFAULT_GENERATE_MECHANISMS,
            mechanism, mechanism_param)

        # Build attributes
        template_ = {
            Attribute.CLASS: ObjectClass.SECRET_KEY,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            Attribute.PRIVATE: True,
            Attribute.SENSITIVE: True,
            # Capabilities
            Attribute.ENCRYPT: MechanismFlag.ENCRYPT & capabilities,
            Attribute.DECRYPT: MechanismFlag.DECRYPT & capabilities,
            Attribute.WRAP: MechanismFlag.WRAP & capabilities,
            Attribute.UNWRAP: MechanismFlag.UNWRAP & capabilities,
            Attribute.SIGN: MechanismFlag.SIGN & capabilities,
            Attribute.VERIFY: MechanismFlag.VERIFY & capabilities,
            Attribute.DERIVE: MechanismFlag.DERIVE & capabilities,
        }

        if key_type is KeyType.AES:
            if key_length is None:
                raise ArgumentsBad("Must provide `key_length'")

            template_[Attribute.VALUE_LEN] = key_length // 8  # In bytes

        attrs = AttributeList(merge_templates(template_, template))

        cdef CK_OBJECT_HANDLE key

        assertRV(_funclist.C_GenerateKey(self._handle,
                               mech.data,
                               attrs.data, attrs.count,
                               &key))

        return Object._make(self, key)

    def _generate_keypair(self, key_type, key_length=None,
                          id=None, label=None,
                          store=False, capabilities=None,
                          mechanism=None, mechanism_param=None,
                          public_template=None, private_template=None):

        if not isinstance(key_type, KeyType):
            raise ArgumentsBad("`key_type` must be KeyType.")

        if key_length is not None and not isinstance(key_length, int):
            raise ArgumentsBad("`key_length` is the length in bits.")

        if capabilities is None:
            try:
                capabilities = DEFAULT_KEY_CAPABILITIES[key_type]
            except KeyError:
                raise ArgumentsBad("No default capabilities for this key "
                                   "type. Please specify `capabilities`.")

        mech = MechanismWithParam(
            key_type, DEFAULT_GENERATE_MECHANISMS,
            mechanism, mechanism_param)

        # Build attributes
        public_template_ = {
            Attribute.CLASS: ObjectClass.PUBLIC_KEY,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            # Capabilities
            Attribute.ENCRYPT: MechanismFlag.ENCRYPT & capabilities,
            Attribute.WRAP: MechanismFlag.WRAP & capabilities,
            Attribute.VERIFY: MechanismFlag.VERIFY & capabilities,
        }

        if key_type is KeyType.RSA:
            if key_length is None:
                raise ArgumentsBad("Must provide `key_length'")

            # Some PKCS#11 implementations don't default this, it makes sense
            # to do it here
            public_template_.update({
                Attribute.PUBLIC_EXPONENT: b'\1\0\1',
                Attribute.MODULUS_BITS: key_length,
            })

        public_attrs = AttributeList(merge_templates(public_template_, public_template))

        private_template_ = {
            Attribute.CLASS: ObjectClass.PRIVATE_KEY,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            Attribute.PRIVATE: True,
            Attribute.SENSITIVE: True,
            # Capabilities
            Attribute.DECRYPT: MechanismFlag.DECRYPT & capabilities,
            Attribute.UNWRAP: MechanismFlag.UNWRAP & capabilities,
            Attribute.SIGN: MechanismFlag.SIGN & capabilities,
            Attribute.DERIVE: MechanismFlag.DERIVE & capabilities,
        }
        private_attrs = AttributeList(merge_templates(private_template_, private_template))

        cdef CK_OBJECT_HANDLE public_key
        cdef CK_OBJECT_HANDLE private_key

        assertRV(_funclist.C_GenerateKeyPair(self._handle,
                                   mech.data,
                                   public_attrs.data, public_attrs.count,
                                   private_attrs.data, private_attrs.count,
                                   &public_key, &private_key))

        return (Object._make(self, public_key),
                Object._make(self, private_key))

    def seed_random(self, seed):
        assertRV(_funclist.C_SeedRandom(self._handle, seed, <CK_ULONG> len(seed)))

    def generate_random(self, nbits):
        length = nbits // 8

        cdef CK_CHAR [:] random = CK_BYTE_buffer(length)

        assertRV(_funclist.C_GenerateRandom(self._handle, &random[0], length))

        return bytes(random)

    def _digest(self, data, mechanism=None, mechanism_param=None):

        mech = MechanismWithParam(None, {}, mechanism, mechanism_param)

        cdef CK_BYTE [:] digest
        cdef CK_ULONG length

        with self._operation_lock:
            assertRV(_funclist.C_DigestInit(self._handle, mech.data))

            # Run once to get the length
            assertRV(_funclist.C_Digest(self._handle,
                              data, <CK_ULONG> len(data),
                              NULL, &length))

            digest = CK_BYTE_buffer(length)

            assertRV(_funclist.C_Digest(self._handle,
                              data, <CK_ULONG> len(data),
                              &digest[0], &length))

            return bytes(digest[:length])

    def _digest_generator(self, data, mechanism=None, mechanism_param=None):
        mech = MechanismWithParam(None, {}, mechanism, mechanism_param)

        cdef CK_BYTE [:] digest
        cdef CK_ULONG length

        with self._operation_lock:
            assertRV(_funclist.C_DigestInit(self._handle, mech.data))

            for block in data:
                if isinstance(block, types.Key):
                    assertRV(_funclist.C_DigestKey(self._handle, block._handle))
                else:
                    assertRV(_funclist.C_DigestUpdate(self._handle, block, <CK_ULONG> len(block)))

            # Run once to get the length
            assertRV(_funclist.C_DigestFinal(self._handle, NULL, &length))

            digest = CK_BYTE_buffer(length)

            assertRV(_funclist.C_DigestFinal(self._handle, &digest[0], &length))

            return bytes(digest[:length])


class Object(types.Object):
    """Expand Object with an implementation."""

    @classmethod
    def _make(cls, *args, **kwargs):
        """
        Make an object with the right bases for its class and capabilities.
        """

        # Make a version of ourselves we can introspect
        self = cls(*args, **kwargs)

        try:
            # Determine a list of base classes to manufacture our class with
            # FIXME: we should really request all of these attributes in
            # one go
            object_class = self[Attribute.CLASS]
            bases = (_CLASS_MAP[object_class],)

            # Build a list of mixins for this new class
            for attribute, mixin in (
                    (Attribute.ENCRYPT, EncryptMixin),
                    (Attribute.DECRYPT, DecryptMixin),
                    (Attribute.SIGN, SignMixin),
                    (Attribute.VERIFY, VerifyMixin),
                    (Attribute.WRAP, WrapMixin),
                    (Attribute.UNWRAP, UnwrapMixin),
                    (Attribute.DERIVE, DeriveMixin),
            ):
                try:
                    if self[attribute]:
                        bases += (mixin,)
                # nFast returns FunctionFailed when you request an attribute
                # it doesn't like.
                except (AttributeTypeInvalid, FunctionFailed):
                    pass

            bases += (cls,)

            # Manufacture a class with the right capabilities.
            klass = type(bases[0].__name__, bases, {})

            return klass(*args, **kwargs)

        except KeyError:
            return self

    def __getitem__(self, key):
        cdef CK_ATTRIBUTE template
        template.type = key
        template.pValue = NULL

        # Find out the attribute size
        assertRV(_funclist.C_GetAttributeValue(self.session._handle, self._handle,
                                     &template, 1))

        if template.ulValueLen == 0:
            return _unpack_attributes(key, b'')

        # Put a buffer of the right length in place
        cdef CK_CHAR [:] value = CK_BYTE_buffer(template.ulValueLen)
        template.pValue = <CK_CHAR *> &value[0]

        # Request the value
        assertRV(_funclist.C_GetAttributeValue(self.session._handle, self._handle,
                                     &template, 1))

        return _unpack_attributes(key, value)

    def __setitem__(self, key, value):
        value = _pack_attribute(key, value)

        cdef CK_ATTRIBUTE template
        template.type = key
        template.pValue = <CK_CHAR *> value
        template.ulValueLen = <CK_ULONG>len(value)

        assertRV(_funclist.C_SetAttributeValue(self.session._handle, self._handle,
                                     &template, 1))

    def copy(self, attrs):
        cdef CK_OBJECT_HANDLE new

        template = AttributeList(attrs)
        assertRV(_funclist.C_CopyObject(self.session._handle, self._handle,
                              template.data, template.count,
                              &new))

        return Object._make(self.session, new)

    def destroy(self):
        assertRV(_funclist.C_DestroyObject(self.session._handle, self._handle))


class SecretKey(types.SecretKey):
    pass


class PublicKey(types.PublicKey):
    pass


class PrivateKey(types.PrivateKey):
    pass


class DomainParameters(types.DomainParameters):
    def generate_keypair(self,
                         id=None, label=None,
                         store=False, capabilities=None,
                         mechanism=None, mechanism_param=None,
                         public_template=None, private_template=None):

        if capabilities is None:
            try:
                capabilities = DEFAULT_KEY_CAPABILITIES[self.key_type]
            except KeyError:
                raise ArgumentsBad("No default capabilities for this key "
                                   "type. Please specify `capabilities`.")

        mech = MechanismWithParam(
            self.key_type, DEFAULT_GENERATE_MECHANISMS,
            mechanism, mechanism_param)

        # Build attributes
        public_template_ = {
            Attribute.CLASS: ObjectClass.PUBLIC_KEY,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            # Capabilities
            Attribute.ENCRYPT: MechanismFlag.ENCRYPT & capabilities,
            Attribute.WRAP: MechanismFlag.WRAP & capabilities,
            Attribute.VERIFY: MechanismFlag.VERIFY & capabilities,
        }

        # Copy in our domain parameters.
        # Not all parameters are appropriate for all domains.
        for attribute in (
                Attribute.BASE,
                Attribute.PRIME,
                Attribute.SUBPRIME,
                Attribute.EC_PARAMS,
        ):
            try:
                public_template_[attribute] = self[attribute]
                # nFast returns FunctionFailed for parameters it doesn't like
            except (AttributeTypeInvalid, FunctionFailed):
                pass

        public_attrs = AttributeList(merge_templates(public_template_, public_template))

        private_template_ = {
            Attribute.CLASS: ObjectClass.PRIVATE_KEY,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            Attribute.PRIVATE: True,
            Attribute.SENSITIVE: True,
            # Capabilities
            Attribute.DECRYPT: MechanismFlag.DECRYPT & capabilities,
            Attribute.UNWRAP: MechanismFlag.UNWRAP & capabilities,
            Attribute.SIGN: MechanismFlag.SIGN & capabilities,
            Attribute.DERIVE: MechanismFlag.DERIVE & capabilities,
        }
        private_attrs = AttributeList(merge_templates(private_template_, private_template))

        cdef CK_OBJECT_HANDLE public_key
        cdef CK_OBJECT_HANDLE private_key

        assertRV(_funclist.C_GenerateKeyPair(self.session._handle,
                                   mech.data,
                                   public_attrs.data, public_attrs.count,
                                   private_attrs.data, private_attrs.count,
                                   &public_key, &private_key))

        return (Object._make(self.session, public_key),
                Object._make(self.session, private_key))


class Certificate(types.Certificate):
    pass


class EncryptMixin(types.EncryptMixin):
    """Expand EncryptMixin with an implementation."""

    def _encrypt(self, data,
                 mechanism=None, mechanism_param=None):
        """
        Non chunking encrypt. Needed for some mechanisms.
        """
        mech = MechanismWithParam(
            self.key_type, DEFAULT_ENCRYPT_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_BYTE [:] ciphertext
        cdef CK_ULONG length

        with self.session._operation_lock:
            assertRV(_funclist.C_EncryptInit(self.session._handle,
                                   mech.data, self._handle))

            # Call to find out the buffer length
            assertRV(_funclist.C_Encrypt(self.session._handle,
                               data, <CK_ULONG> len(data),
                               NULL, &length))

            ciphertext = CK_BYTE_buffer(length)

            assertRV(_funclist.C_Encrypt(self.session._handle,
                               data, <CK_ULONG> len(data),
                               &ciphertext[0], &length))

            return bytes(ciphertext[:length])


    def _encrypt_generator(self, data,
                           mechanism=None, mechanism_param=None,
                           buffer_size=8192):
        """
        Do chunked encryption.

        Failing to consume the generator will raise GeneratorExit when it
        garbage collects. This will release the lock, but you'll still be
        in the middle of an operation, and all future operations will raise
        OperationActive, see tests/test_iterators.py:test_close_iterators().

        FIXME: cancel the operation when we exit the generator early.
        """
        mech = MechanismWithParam(
            self.key_type, DEFAULT_ENCRYPT_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_ULONG length
        cdef CK_BYTE [:] part_out = CK_BYTE_buffer(buffer_size)

        with self.session._operation_lock:
            assertRV(_funclist.C_EncryptInit(self.session._handle,
                                   mech.data, self._handle))

            for part_in in data:
                if not part_in:
                    continue

                length = buffer_size
                assertRV(_funclist.C_EncryptUpdate(self.session._handle,
                                        part_in, <CK_ULONG> len(part_in),
                                        &part_out[0], &length))

                yield bytes(part_out[:length])

            # Finalize
            # We assume the buffer is much bigger than the block size
            length = buffer_size
            assertRV(_funclist.C_EncryptFinal(self.session._handle,
                                    &part_out[0], &length))

            yield bytes(part_out[:length])


class DecryptMixin(types.DecryptMixin):
    """Expand DecryptMixin with an implementation."""

    def _decrypt(self, data,
                 mechanism=None, mechanism_param=None):
        """Non chunking decrypt."""
        mech = MechanismWithParam(
            self.key_type, DEFAULT_ENCRYPT_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_BYTE [:] plaintext
        cdef CK_ULONG length

        with self.session._operation_lock:
            assertRV(_funclist.C_DecryptInit(self.session._handle,
                                   mech.data, self._handle))

            # Call to find out the buffer length
            assertRV(_funclist.C_Decrypt(self.session._handle,
                               data, <CK_ULONG> len(data),
                               NULL, &length))

            plaintext = CK_BYTE_buffer(length)

            assertRV(_funclist.C_Decrypt(self.session._handle,
                               data, <CK_ULONG> len(data),
                               &plaintext[0], &length))

            return bytes(plaintext[:length])


    def _decrypt_generator(self, data,
                           mechanism=None, mechanism_param=None,
                           buffer_size=8192):
        """
        Chunking decrypt.

        Failing to consume the generator will raise GeneratorExit when it
        garbage collects. This will release the lock, but you'll still be
        in the middle of an operation, and all future operations will raise
        OperationActive, see tests/test_iterators.py:test_close_iterators().

        FIXME: cancel the operation when we exit the generator early.
        """
        mech = MechanismWithParam(
            self.key_type, DEFAULT_ENCRYPT_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_ULONG length
        cdef CK_BYTE [:] part_out = CK_BYTE_buffer(buffer_size)

        with self.session._operation_lock:
            assertRV(_funclist.C_DecryptInit(self.session._handle,
                                   mech.data, self._handle))

            for part_in in data:
                if not part_in:
                    continue

                length = buffer_size

                assertRV(_funclist.C_DecryptUpdate(self.session._handle,
                                        part_in, <CK_ULONG> len(part_in),
                                        &part_out[0], &length))

                yield bytes(part_out[:length])

            # Finalize
            # We assume the buffer is much bigger than the block size
            length = buffer_size
            assertRV(_funclist.C_DecryptFinal(self.session._handle,
                                    &part_out[0], &length))

            yield bytes(part_out[:length])


class SignMixin(types.SignMixin):
    """Expand SignMixin with an implementation."""

    def _sign(self, data,
              mechanism=None, mechanism_param=None):

        mech = MechanismWithParam(
            self.key_type, DEFAULT_SIGN_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_BYTE [:] signature
        cdef CK_ULONG length

        with self.session._operation_lock:
            assertRV(_funclist.C_SignInit(self.session._handle, mech.data, self._handle))

            # Call to find out the buffer length
            assertRV(_funclist.C_Sign(self.session._handle,
                            data, <CK_ULONG> len(data),
                            NULL, &length))

            signature = CK_BYTE_buffer(length)

            assertRV(_funclist.C_Sign(self.session._handle,
                            data, <CK_ULONG> len(data),
                            &signature[0], &length))

            return bytes(signature[:length])

    def _sign_generator(self, data,
                        mechanism=None, mechanism_param=None):

        mech = MechanismWithParam(
            self.key_type, DEFAULT_SIGN_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_BYTE [:] signature
        cdef CK_ULONG length

        with self.session._operation_lock:
            assertRV(_funclist.C_SignInit(self.session._handle, mech.data, self._handle))

            for part_in in data:
                if not part_in:
                    continue

                assertRV(_funclist.C_SignUpdate(self.session._handle,
                                      part_in, <CK_ULONG> len(part_in)))

            # Finalize
            # Call to find out the buffer length
            assertRV(_funclist.C_SignFinal(self.session._handle,
                                 NULL, &length))

            signature = CK_BYTE_buffer(length)

            assertRV(_funclist.C_SignFinal(self.session._handle,
                                 &signature[0], &length))

            return bytes(signature[:length])


class VerifyMixin(types.VerifyMixin):
    """Expand VerifyMixin with an implementation."""

    def _verify(self, data, signature,
                mechanism=None, mechanism_param=None):

        mech = MechanismWithParam(
            self.key_type, DEFAULT_SIGN_MECHANISMS,
            mechanism, mechanism_param)

        with self.session._operation_lock:
            assertRV(_funclist.C_VerifyInit(self.session._handle,
                                  mech.data, self._handle))

            # Call to find out the buffer length
            assertRV(_funclist.C_Verify(self.session._handle,
                              data, <CK_ULONG> len(data),
                              signature, <CK_ULONG> len(signature)))

    def _verify_generator(self, data, signature,
                          mechanism=None, mechanism_param=None):

        mech = MechanismWithParam(
            self.key_type, DEFAULT_SIGN_MECHANISMS,
            mechanism, mechanism_param)

        with self.session._operation_lock:
            assertRV(_funclist.C_VerifyInit(self.session._handle,
                                  mech.data, self._handle))

            for part_in in data:
                if not part_in:
                    continue

                assertRV(_funclist.C_VerifyUpdate(self.session._handle,
                                        part_in, <CK_ULONG> len(part_in)))


            assertRV(_funclist.C_VerifyFinal(self.session._handle,
                                   signature, <CK_ULONG> len(signature)))


class WrapMixin(types.WrapMixin):
    """Expand WrapMixin with an implementation."""

    def wrap_key(self, key,
                 mechanism=None, mechanism_param=None):

        if not isinstance(key, types.Key):
            raise ArgumentsBad("`key` must be a Key.")

        mech = MechanismWithParam(
            self.key_type, DEFAULT_WRAP_MECHANISMS,
            mechanism, mechanism_param)

        cdef CK_ULONG length

        # Find out how many bytes we need to allocate
        assertRV(_funclist.C_WrapKey(self.session._handle,
                           mech.data,
                           self._handle,
                           key._handle,
                           NULL, &length))

        cdef CK_BYTE [:] data = CK_BYTE_buffer(length)

        assertRV(_funclist.C_WrapKey(self.session._handle,
                           mech.data,
                           self._handle,
                           key._handle,
                           &data[0], &length))

        return bytes(data[:length])


class UnwrapMixin(types.UnwrapMixin):
    """Expand UnwrapMixin with an implementation."""

    def unwrap_key(self, object_class, key_type, key_data,
                   id=None, label=None,
                   mechanism=None, mechanism_param=None,
                   store=False, capabilities=None,
                   template=None):

        if not isinstance(object_class, ObjectClass):
            raise ArgumentsBad("`object_class` must be ObjectClass.")

        if not isinstance(key_type, KeyType):
            raise ArgumentsBad("`key_type` must be KeyType.")

        if capabilities is None:
            try:
                capabilities = DEFAULT_KEY_CAPABILITIES[key_type]
            except KeyError:
                raise ArgumentsBad("No default capabilities for this key "
                                   "type. Please specify `capabilities`.")

        mech = MechanismWithParam(
            self.key_type, DEFAULT_WRAP_MECHANISMS,
            mechanism, mechanism_param)

        # Build attributes
        template_ = {
            Attribute.CLASS: object_class,
            Attribute.KEY_TYPE: key_type,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            # Capabilities
            Attribute.ENCRYPT: MechanismFlag.ENCRYPT & capabilities,
            Attribute.DECRYPT: MechanismFlag.DECRYPT & capabilities,
            Attribute.WRAP: MechanismFlag.WRAP & capabilities,
            Attribute.UNWRAP: MechanismFlag.UNWRAP & capabilities,
            Attribute.SIGN: MechanismFlag.SIGN & capabilities,
            Attribute.VERIFY: MechanismFlag.VERIFY & capabilities,
            Attribute.DERIVE: MechanismFlag.DERIVE & capabilities,
        }
        attrs = AttributeList(merge_templates(template_, template))

        cdef CK_OBJECT_HANDLE key

        assertRV(_funclist.C_UnwrapKey(self.session._handle,
                             mech.data,
                             self._handle,
                             key_data, <CK_ULONG> len(key_data),
                             attrs.data, attrs.count,
                             &key))

        return Object._make(self.session, key)


class DeriveMixin(types.DeriveMixin):
    """Expand DeriveMixin with an implementation."""

    def derive_key(self, key_type, key_length,
                   id=None, label=None,
                   store=False, capabilities=None,
                   mechanism=None, mechanism_param=None,
                   template=None):

        if not isinstance(key_type, KeyType):
            raise ArgumentsBad("`key_type` must be KeyType.")

        if not isinstance(key_length, int):
            raise ArgumentsBad("`key_length` is the length in bits.")

        if capabilities is None:
            try:
                capabilities = DEFAULT_KEY_CAPABILITIES[key_type]
            except KeyError:
                raise ArgumentsBad("No default capabilities for this key "
                                   "type. Please specify `capabilities`.")

        mech = MechanismWithParam(
            self.key_type, DEFAULT_DERIVE_MECHANISMS,
            mechanism, mechanism_param)

        # Build attributes
        template_ = {
            Attribute.CLASS: ObjectClass.SECRET_KEY,
            Attribute.KEY_TYPE: key_type,
            Attribute.ID: id or b'',
            Attribute.LABEL: label or '',
            Attribute.TOKEN: store,
            Attribute.VALUE_LEN: key_length // 8,  # In bytes
            Attribute.PRIVATE: True,
            Attribute.SENSITIVE: True,
            # Capabilities
            Attribute.ENCRYPT: MechanismFlag.ENCRYPT & capabilities,
            Attribute.DECRYPT: MechanismFlag.DECRYPT & capabilities,
            Attribute.WRAP: MechanismFlag.WRAP & capabilities,
            Attribute.UNWRAP: MechanismFlag.UNWRAP & capabilities,
            Attribute.SIGN: MechanismFlag.SIGN & capabilities,
            Attribute.VERIFY: MechanismFlag.VERIFY & capabilities,
            Attribute.DERIVE: MechanismFlag.DERIVE & capabilities,
        }
        attrs = AttributeList(merge_templates(template_, template))

        cdef CK_OBJECT_HANDLE key

        assertRV(_funclist.C_DeriveKey(self.session._handle,
                             mech.data,
                             self._handle,
                             attrs.data, attrs.count,
                             &key))

        return Object._make(self.session, key)


_CLASS_MAP = {
    ObjectClass.SECRET_KEY: SecretKey,
    ObjectClass.PUBLIC_KEY: PublicKey,
    ObjectClass.PRIVATE_KEY: PrivateKey,
    ObjectClass.DOMAIN_PARAMETERS: DomainParameters,
    ObjectClass.CERTIFICATE: Certificate,
}


cdef class lib:
    """
    Main entry point.

    This class needs to be defined cdef, so it can't shadow a class in
    pkcs11.types.
    """

    cdef public str so
    cdef public str manufacturer_id
    cdef public str library_description
    cdef public tuple cryptoki_version
    cdef public tuple library_version
    IF UNAME_SYSNAME == "Windows":
        cdef mswin.HMODULE _handle
    ELSE:
        cdef void *_handle

    cdef _load_pkcs11_lib(self, so) with gil:
        """Load a PKCS#11 library, and extract function calls.

        This method will dynamically load a PKCS11 library, and attempt to
        resolve the symbol 'C_GetFunctionList()'. Once found, the entry point
        is called to populate an internal table of function pointers.

        This is a private method, and must never be called directly.
        Called when a new lib class is instantiated.

        :param so: the path to a valid PKCS#11 library
        :type so: str
        :raises: RuntimeError or PKCS11Error
        :rtype: None
        """

        # to keep a pointer to the C_GetFunctionList address returned by dlsym()
        cdef C_GetFunctionList_ptr C_GetFunctionList

        IF UNAME_SYSNAME == "Windows":
            self._handle = mswin.LoadLibraryW(so)
            if self._handle == NULL:
                raise RuntimeError("Cannot open library at {}: {}".format(so, mswin.winerror(so)))

            if self._handle != NULL:
                C_GetFunctionList = <C_GetFunctionList_ptr> mswin.GetProcAddress(self._handle, 'C_GetFunctionList')
                if C_GetFunctionList == NULL:
                    raise RuntimeError("{} is not a PKCS#11 library: {}".format(so, mswin.winerror(so)))
        ELSE:
            self._handle = dlfcn.dlopen(so.encode('utf-8'), dlfcn.RTLD_LAZY | dlfcn.RTLD_LOCAL)
            if self._handle == NULL:
                raise RuntimeError(dlfcn.dlerror())

            C_GetFunctionList = <C_GetFunctionList_ptr> dlfcn.dlsym(self._handle, 'C_GetFunctionList')
            if C_GetFunctionList == NULL:
                raise RuntimeError("{} is not a PKCS#11 library: {}".format(so, dlfcn.dlerror()))

        assertRV(C_GetFunctionList(&_funclist))


    cdef _unload_pkcs11_lib(self) with gil:
        """Unload a PKCS#11 library.

        This method will dynamically unload a PKCS11 library.

        This is a private method, and must never be called directly.
        Called when a lib instance is destroyed.
        """

        IF UNAME_SYSNAME == "Windows":
            if self._handle != NULL:
                mswin.FreeLibrary(self._handle)
        ELSE:
            if self._handle != NULL:
                dlfcn.dlclose(self._handle)

    def __cinit__(self, so):
        self._load_pkcs11_lib(so)
        # at this point, _funclist contains all function pointers to the library
        assertRV(_funclist.C_Initialize(NULL))

    def __init__(self, so):
        self.so = so
        cdef CK_INFO info
        assertRV(_funclist.C_GetInfo(&info))

        _fix_string_length(info.manufacturerID,
                           sizeof(info.manufacturerID))
        _fix_string_length(info.libraryDescription,
                           sizeof(info.libraryDescription))

        self.manufacturer_id = _CK_UTF8CHAR_to_str(info.manufacturerID)
        self.library_description = _CK_UTF8CHAR_to_str(info.libraryDescription)
        self.cryptoki_version = _CK_VERSION_to_tuple(info.cryptokiVersion)
        self.library_version = _CK_VERSION_to_tuple(info.libraryVersion)

    def __str__(self):
        return '\n'.join((
            "Library: %s" % self.so,
            "Manufacturer ID: %s" % self.manufacturer_id,
            "Library Description: %s" % self.library_description,
            "Cryptoki Version: %s.%s" % self.cryptoki_version,
            "Library Version: %s.%s" % self.library_version,
        ))

    def __repr__(self):
        return '<pkcs11.lib ({so})>'.format(
            so=self.so)


    def get_slots(self, token_present=False):
        """Get all slots."""

        cdef CK_ULONG count

        assertRV(_funclist.C_GetSlotList(token_present, NULL, &count))

        if count == 0:
            return []

        cdef CK_ULONG [:] slotIDs = CK_ULONG_buffer(count)

        assertRV(_funclist.C_GetSlotList(token_present, &slotIDs[0], &count))

        cdef CK_SLOT_INFO info
        slots = []

        for slotID in slotIDs:
            assertRV(_funclist.C_GetSlotInfo(slotID, &info))

            _fix_string_length(info.slotDescription,
                               sizeof(info.slotDescription))
            _fix_string_length(info.manufacturerID,
                               sizeof(info.manufacturerID))

            slots.append(Slot(self, slotID, **info))

        return slots


    def get_tokens(self,
                   token_label=None,
                   token_serial=None,
                   token_flags=None,
                   slot_flags=None,
                   mechanisms=None):
        """Search for a token matching the parameters."""

        for slot in self.get_slots():
            try:
                token = slot.get_token()
                token_mechanisms = slot.get_mechanisms()
            
                if token_label is not None and \
                        token.label != token_label:
                    continue

                if token_serial is not None and \
                        token.serial != token_serial:
                    continue

                if token_flags is not None and \
                        not token.flags & token_flags:
                    continue

                if slot_flags is not None and \
                        not slot.flags & slot_flags:
                    continue

                if mechanisms is not None and \
                        set(mechanisms) not in token_mechanisms:
                    continue

                yield token
            except (TokenNotPresent, TokenNotRecognised):
                continue

    def get_token(self, **kwargs):
        """Get a single token."""
        iterator = self.get_tokens(**kwargs)

        try:
            token = next(iterator)
        except StopIteration:
            raise NoSuchToken("No token matching %s" % kwargs)

        try:
            next(iterator)
            raise MultipleTokensReturned(
                "More than 1 token matches %s" % kwargs)
        except StopIteration:
            return token

    def __dealloc__(self):
        if _funclist != NULL:
            assertRV(_funclist.C_Finalize(NULL))

        self._unload_pkcs11_lib()
