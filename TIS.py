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
        Gst.init([]) # Usually better to call in the main function.
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
        Start the pipeline, so the video runs
        """
        self.pipeline.set_state(Gst.State.PLAYING)
        self.pipeline.get_state(2000000000)
        return True

    def Get_image(self):
        return self.img_mat


    def Stop_pipeline(self):
        self.pipeline.set_state(Gst.State.PAUSED)
        self.pipeline.set_state(Gst.State.READY)
        self.pipeline.set_state(Gst.State.NULL)
        

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
                raise Exception( name + " : " + error.message )


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
            raise Exception(PropertyName + " : " + error.message )

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
            raise Exception(PropertyName + " : " + error.message )


    def execute_command(self, PropertyName ):
        '''
        Execute a command property like Software Trigger
        If something fails an exception is thrown.
        :param PropertyName: Name of the property to set
        '''
        try:
            baseproperty = self.source.get_tcam_property(PropertyName)
            baseproperty.set_command()
        except GLib.Error as error:
            raise Exception( PropertyName + " : " + error.message )


    def Set_Image_Callback(self, function, *data):
        self.ImageCallback = function
        self.ImageCallbackData = data


    def loadstatefile(self, filename):
        '''
        Load the complete device configuration from a json file
        :param filename: filename to be used.
        '''
        try:
            with open(filename) as jsonFile:
                devicestate = json.load(jsonFile)
                jsonFile.close()

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
            if serial is not None:
                if serial != "":
                    self.source.set_property("serial", serial)

           

            print("Sink config")
            appsink = self.pipeline.get_by_name("sink")
            if appsink is not None:
                appsink.set_property("max-buffers",5)
                appsink.set_property("drop",1)
                appsink.set_property("emit-signals",1)
                appsink.connect('new-sample', self.on_new_buffer)

            print("READY state")
            self.pipeline.set_state(Gst.State.READY)
            print("GET state")
            self.pipeline.get_state(4000000000)

             # 1. Set to READY to "wake up" the driver
            self.pipeline.set_state(Gst.State.READY)

            res, _, _ = self.pipeline.get_state(2 * Gst.SECOND)

            if res == Gst.StateChangeReturn.SUCCESS:
                print("Camera in READY state. Applying properties...")
                # 2. Apply the JSON properties (this turns Trigger Mode OFF)
                state_json = json.dumps(devicestate['properties'])
                self.source.set_property("tcam-properties-json", state_json)

            else:
                print("Failed to reach READY state. Camera might be busy or disconnected.")



            print("Camera configured and open.")

        except Exception as msg:
            print("ERROR loading device json: ", msg )        
