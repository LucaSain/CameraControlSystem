import time
from collections import namedtuple

import gi
import re
import numpy
import json
from enum import Enum
gi.require_version("Gst", "1.0")
gi.require_version("Tcam", "1.0")

from gi.repository import GLib, GObject, Gst, Tcam


class TIS:
    'The Imaging Source Camera'

    def __init__(self):
        ''' Constructor
        :return: none
        '''
        Gst.init([])  # Usually better to call in the main function.
        Gst.debug_set_default_threshold(Gst.DebugLevel.WARNING)
        self.serialnumber = ""
        self.height = 0
        self.width = 0
        self.framerate = "15/1"
        self.livedisplay = True
        self.sample = None
        self.samplelocked = False
        self.newsample = False
        self.img_mat = None
        self.ImageCallback = None
        self.ImageCallbackData = ()
        self.pipeline = None
        self.source = None
        self.frame_count = 0
        self.fps_start_time = time.time()
        self.current_hardware_fps = 0.0

    def on_new_buffer(self, appsink):
        # 1. Pull the sample from the appsink signal
        sample = appsink.emit("pull-sample")

        if sample:
            # 2. Process the frame
            self.sample = sample
            self.__convert_sample_to_numpy()
            self.newsample = True

            # 3. FPS Calculation Logic
            self.frame_count += 1
            now = time.time()
            elapsed = now - self.fps_start_time

            # Update the console every 1 second
            if elapsed >= 1.0:
                self.current_hardware_fps = self.frame_count / elapsed
                print(f"DEBUG: Hardware FPS: {self.current_hardware_fps:.2f} | Res: {self.width}x{self.height}")

                # Reset counters for the next second
                self.frame_count = 0
                self.fps_start_time = now

            # 4. Trigger external callback if defined
            if self.ImageCallback is not None:
                self.ImageCallback(self, *self.ImageCallbackData)

        return Gst.FlowReturn.OK

    def __convert_sample_to_numpy(self):
        self.samplelocked = True
        buf = self.sample.get_buffer()
        caps = self.sample.get_caps()
        s = caps.get_structure(0)

        _, self.width = s.get_int("width")
        _, self.height = s.get_int("height")
        fmt = s.get_string("format")

        success, info = buf.map(Gst.MapFlags.READ)
        if success:
            if fmt == "GRAY8":
                # Grayscale is 1 byte per pixel, 2D array
                self.img_mat = numpy.ndarray((self.height, self.width),
                                             buffer=info.data,
                                             dtype=numpy.uint8)
            buf.unmap(info)
        self.samplelocked = False

    def Start_pipeline(self):
        """
        Start the pipeline, so the video runs.
        Raises RuntimeError if the pipeline was never built (camera failed to load),
        so the caller can handle it instead of hitting a raw AttributeError.
        """
        if self.pipeline is None:
            raise RuntimeError("Pipeline not initialized (camera failed to load).")
        self.pipeline.set_state(Gst.State.PLAYING)
        self.pipeline.get_state(2000000000)
        return True

    def Get_image(self):
        return self.img_mat

    def Stop_pipeline(self):
        """
        Cleanly tear the pipeline down and RELEASE THE CAMERA.

        The device-list lock and sensor power-down happen during the
        READY->NULL transition inside tcampimipisrc. That transition is
        asynchronous, so we must BLOCK with get_state() until it actually
        completes -- otherwise the process can exit mid-teardown and strand
        the lock / leave the sensor powered.

        Safe to call when the pipeline was never built (no-op) and safe to
        call more than once (idempotent).
        """
        if self.pipeline is None:
            return
        try:
            self.pipeline.set_state(Gst.State.NULL)
            # Block until the NULL transition has fully completed (camera released).
            self.pipeline.get_state(Gst.SECOND * 5)
        except Exception as error:
            print(f"WARNING: error during pipeline teardown: {error}")
        finally:
            # Drop references so a second call is a clean no-op and GC can run.
            self.source = None
            self.pipeline = None

    def get_source(self):
        '''
        Return the source element of the pipeline.
        '''
        return self.source

    def List_Properties(self):
        property_names = self.source.get_tcam_property_names()

        for name in property_names:
            try:
                base = self.source.get_tcam_property(name)
                print("{}\t{}".format(base.get_display_name(),
                                      name
                                      ))
            except Exception as error:
                raise Exception(name + " : " + error.message)

    def Get_Property(self, PropertyName):
        """
        Return the value of the passed property.
        If something fails an
        exception is thrown.
        :param PropertyName: Name of the property to set
        :return: Current value of the property
        """
        try:
            baseproperty = self.source.get_tcam_property(PropertyName)
            val = baseproperty.get_value()
            return val

        except GLib.Error as error:
            raise Exception(PropertyName + " : " + error.message)

    def Set_Property(self, PropertyName, value):
        '''
        Pass a new value to a camera property. If something fails an
        exception is thrown.
        :param PropertyName: Name of the property to set
        :param value: Property value. Can be of type int, float, string and boolean
        '''
        try:
            baseproperty = self.source.get_tcam_property(PropertyName)
            baseproperty.set_value(value)
        except GLib.Error as error:
            raise Exception(PropertyName + " : " + error.message)

    def execute_command(self, PropertyName):
        '''
        Execute a command property like Software Trigger
        If something fails an exception is thrown.
        :param PropertyName: Name of the property to set
        '''
        try:
            baseproperty = self.source.get_tcam_property(PropertyName)
            baseproperty.set_command()
        except GLib.Error as error:
            raise Exception(PropertyName + " : " + error.message)

    def get_property_info(self, name):
        '''
        Return a dict describing a single property: its value, inferred control
        type, range or enum options, and whether it is currently writable
        (available / not locked). Every introspection call is best-effort and
        wrapped, so version differences in the tcam API degrade gracefully
        instead of raising.
        '''
        info = {"name": name}
        try:
            prop = self.source.get_tcam_property(name)
        except Exception as error:
            return {"name": name, "available": False, "locked": True,
                    "error": str(error)}

        # Human-readable metadata (best-effort).
        for attr, key in (("get_display_name", "display_name"),
                          ("get_category", "category"),
                          ("get_unit", "unit")):
            try:
                fn = getattr(prop, attr, None)
                if fn:
                    val = fn()
                    if val:
                        info[key] = val
            except Exception:
                pass

        # Writability state. This is what tells the UI a property cannot be set
        # right now (e.g. ExposureTime while ExposureAuto is on, or geometry
        # while streaming).
        for attr, key, default in (("is_available", "available", True),
                                   ("is_locked", "locked", False)):
            try:
                fn = getattr(prop, attr, None)
                info[key] = bool(fn()) if fn else default
            except Exception:
                info[key] = default

        # Current value (commands have none).
        value = None
        try:
            value = prop.get_value()
        except Exception:
            value = None
        info["value"] = value

        # Enum options.
        try:
            fn = getattr(prop, "get_enum_entries", None)
            if fn:
                entries = list(fn())
                if entries:
                    info["type"] = "enum"
                    info["options"] = entries
        except Exception:
            pass

        # Numeric range (min, max[, step]).
        if "type" not in info:
            try:
                fn = getattr(prop, "get_range", None)
                if fn:
                    rng = fn()
                    if rng and len(rng) >= 2:
                        info["min"] = rng[0]
                        info["max"] = rng[1]
                        if len(rng) >= 3 and rng[2]:
                            info["step"] = rng[2]
            except Exception:
                pass

        # Fall back to inferring the control type from the Python value type.
        # bool must be checked before int (bool is a subclass of int).
        if "type" not in info:
            if isinstance(value, bool):
                info["type"] = "bool"
            elif isinstance(value, int):
                info["type"] = "int"
            elif isinstance(value, float):
                info["type"] = "float"
            elif isinstance(value, str):
                info["type"] = "string"
            elif value is None:
                info["type"] = "command"
            else:
                info["type"] = "unknown"

        return info

    def list_properties_info(self):
        '''Return get_property_info() for every property the camera exposes.'''
        try:
            names = self.source.get_tcam_property_names()
        except Exception:
            names = []
        return [self.get_property_info(n) for n in names]

    def set_property_smart(self, name, raw_value):
        '''
        Set a property, coercing the incoming (string) value to the type the
        property expects. Returns the read-back value. Raises on failure so the
        caller can report which property/value was rejected.
        '''
        prop = self.source.get_tcam_property(name)

        current = None
        try:
            current = prop.get_value()
        except Exception:
            current = None

        if isinstance(current, bool):
            coerced = str(raw_value).strip().lower() in ("1", "true", "on", "yes")
        elif isinstance(current, int):
            coerced = int(float(raw_value))
        elif isinstance(current, float):
            coerced = float(raw_value)
        else:
            coerced = raw_value  # string / enum value passed through

        prop.set_value(coerced)
        try:
            return prop.get_value()
        except Exception:
            return coerced

    def Set_Image_Callback(self, function, *data):
        self.ImageCallback = function
        self.ImageCallbackData = data

    def loadstatefile(self, filename):
        '''
        Load the complete device configuration from a json file
        :param filename: filename to be used.

        On any failure self.pipeline is left as None so that the rest of the
        application (and the shutdown path) can detect that the camera did not
        come up, instead of operating on a half-built pipeline.
        '''
        try:
            with open(filename) as jsonFile:
                devicestate = json.load(jsonFile)

            serial = devicestate['serial']

            capsstring = "video/x-raw,format=GRAY8,width={0},height={1},framerate={2}".format(
                devicestate['width'],
                devicestate['height'],
                devicestate['framerate']
            )

            pipestr = devicestate['pipeline'].format(capsstring)
            print(pipestr)
            self.pipeline = Gst.parse_launch(pipestr)
            print(self.pipeline)

            print("Opening camera with serial: ", serial)
            self.source = self.pipeline.get_by_name("tcam0")

            print("Checking serial")
            if serial is not None and serial != "":
                self.source.set_property("serial", serial)

            print("Sink config")
            appsink = self.pipeline.get_by_name("sink")
            if appsink is not None:
                appsink.set_property("max-buffers", 5)
                appsink.set_property("drop", 1)
                appsink.set_property("emit-signals", 1)
                appsink.connect('new-sample', self.on_new_buffer)

            print("READY state")
            self.pipeline.set_state(Gst.State.READY)
            print("GET state")
            self.pipeline.get_state(4000000000)

            # Set to READY to "wake up" the driver
            self.pipeline.set_state(Gst.State.READY)
            res, _, _ = self.pipeline.get_state(2 * Gst.SECOND)

            if res == Gst.StateChangeReturn.SUCCESS:
                print("Camera in READY state. Applying properties...")
                state_json = json.dumps(devicestate['properties'])
                self.source.set_property("tcam-properties-json", state_json)
            else:
                print("Failed to reach READY state. Camera might be busy or disconnected.")

            print("Camera configured and open.")

        except Exception as msg:
            print("ERROR loading device json: ", msg)
            # Make sure a partially-built pipeline does not linger.
            try:
                if self.pipeline is not None:
                    self.pipeline.set_state(Gst.State.NULL)
                    self.pipeline.get_state(Gst.SECOND * 5)
            except Exception:
                pass
            self.source = None
            self.pipeline = None
