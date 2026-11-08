package com.winlator.xserver.extensions;

import static com.winlator.xserver.XClientRequestHandler.RESPONSE_CODE_SUCCESS;

import com.winlator.xconnector.XInputStream;
import com.winlator.xconnector.XOutputStream;
import com.winlator.xconnector.XStreamLock;
import com.winlator.xserver.Window;
import com.winlator.xserver.XClient;
import com.winlator.xserver.XServer;
import com.winlator.xserver.errors.BadWindow;
import com.winlator.xserver.errors.XRequestError;

import java.io.IOException;

/**
 * Minimal X Shape extension (SHAPE) implementation.
 *
 * <p>Wine 11.x calls this extension whenever an application sets a window region
 * (SetWindowRgn). Without it wine logs
 * {@code Xlib: extension "SHAPE" missing on display ":0"} and the region call fails,
 * which makes Winlator's desktop shell (wfm.exe) abort before drawing the taskbar and
 * desktop icons.
 *
 * <p>The implementation accepts all shape requests and reports the windows as
 * unshaped (their full bounding rectangle). That is enough for wine to proceed;
 * the windows are rendered as plain rectangles because the X server does not clip
 * them to a region.
 */
public class ShapeExtension extends Extension {
    public static final short MAJOR_VERSION = 1;
    public static final short MINOR_VERSION = 1;

    private static abstract class ClientOpcodes {
        private static final byte QUERY_VERSION = 0;
        private static final byte RECTANGLES = 1;
        private static final byte MASK = 2;
        private static final byte COMBINE = 3;
        private static final byte OFFSET = 4;
        private static final byte QUERY_EXTENTS = 5;
        private static final byte SELECT_INPUT = 6;
        private static final byte INPUT_SELECTED = 7;
        private static final byte GET_RECTANGLES = 8;
    }

    public ShapeExtension(XServer xServer, byte majorOpcode) {
        super(xServer, majorOpcode);
    }

    @Override
    public String getName() {
        return "SHAPE";
    }

    private void queryVersion(XClient client, XInputStream inputStream, XOutputStream outputStream) throws IOException, XRequestError {
        inputStream.skip(client.getRequestLength());

        try (XStreamLock lock = outputStream.lock()) {
            outputStream.writeByte(RESPONSE_CODE_SUCCESS);
            outputStream.writeByte((byte)0);
            outputStream.writeShort(client.getSequenceNumber());
            outputStream.writeInt(0);
            outputStream.writeShort(MAJOR_VERSION);
            outputStream.writeShort(MINOR_VERSION);
            outputStream.writePad(20);
        }
    }

    private Window getWindow(int id) throws BadWindow {
        Window window = xServer.windowManager.getWindow(id);
        if (window == null) throw new BadWindow(id);
        return window;
    }

    private void queryExtents(XClient client, XInputStream inputStream, XOutputStream outputStream) throws IOException, XRequestError {
        int windowId = inputStream.readInt();
        inputStream.skip(client.getRequestLength() - 4);

        Window window = getWindow(windowId);

        try (XStreamLock lock = outputStream.lock()) {
            outputStream.writeByte(RESPONSE_CODE_SUCCESS);
            outputStream.writeByte((byte)0);
            outputStream.writeShort(client.getSequenceNumber());
            outputStream.writeInt(0);
            outputStream.writeByte((byte)0);
            outputStream.writePad(3);
            writeRectangle(outputStream, window);
            writeRectangle(outputStream, window);
            outputStream.writePad(4);
        }
    }

    private void inputSelected(XClient client, XInputStream inputStream, XOutputStream outputStream) throws IOException, XRequestError {
        inputStream.skip(client.getRequestLength());

        try (XStreamLock lock = outputStream.lock()) {
            outputStream.writeByte(RESPONSE_CODE_SUCCESS);
            outputStream.writeByte((byte)0);
            outputStream.writeShort(client.getSequenceNumber());
            outputStream.writeInt(0);
            outputStream.writeByte((byte)0);
            outputStream.writePad(23);
        }
    }

    private void getRectangles(XClient client, XInputStream inputStream, XOutputStream outputStream) throws IOException, XRequestError {
        int windowId = inputStream.readInt();
        inputStream.skip(client.getRequestLength() - 4);

        Window window = getWindow(windowId);

        try (XStreamLock lock = outputStream.lock()) {
            outputStream.writeByte(RESPONSE_CODE_SUCCESS);
            outputStream.writeByte((byte)0);
            outputStream.writeShort(client.getSequenceNumber());
            outputStream.writeInt(2);
            outputStream.writePad(24);
            writeRectangle(outputStream, window);
        }
    }

    private static void writeRectangle(XOutputStream outputStream, Window window) throws IOException {
        outputStream.writeShort(window.getX());
        outputStream.writeShort(window.getY());
        outputStream.writeShort(window.getWidth());
        outputStream.writeShort(window.getHeight());
    }

    @Override
    public void handleRequest(XClient client, XInputStream inputStream, XOutputStream outputStream) throws IOException, XRequestError {
        byte opcode = client.getRequestData();
        switch (opcode) {
            case ClientOpcodes.QUERY_VERSION:
                queryVersion(client, inputStream, outputStream);
                break;
            case ClientOpcodes.QUERY_EXTENTS:
                queryExtents(client, inputStream, outputStream);
                break;
            case ClientOpcodes.INPUT_SELECTED:
                inputSelected(client, inputStream, outputStream);
                break;
            case ClientOpcodes.GET_RECTANGLES:
                getRectangles(client, inputStream, outputStream);
                break;
            case ClientOpcodes.RECTANGLES:
            case ClientOpcodes.MASK:
            case ClientOpcodes.COMBINE:
            case ClientOpcodes.OFFSET:
            case ClientOpcodes.SELECT_INPUT:
            default:
                inputStream.skip(client.getRequestLength());
                break;
        }
    }
}