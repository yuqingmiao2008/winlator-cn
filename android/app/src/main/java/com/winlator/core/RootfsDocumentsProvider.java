/*
 * 供外部应用 (系统文件管理器 / SAF 文件选择器 / 第三方 App) 浏览、读写
 * Winlator 容器 rootfs/home 目录的 DocumentsProvider。
 *
 * 对应 Issue #1 (添加文件提供器):
 * 暴露 /data/data/com.winlator.cn/files/rootfs/home 为文档树，
 * 其他应用可通过 ACTION_OPEN_DOCUMENT / ACTION_OPEN_DOCUMENT_TREE
 * 看到并读写容器内 home 目录的文件，无需 root。
 */
package com.winlator.core;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Point;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import android.webkit.MimeTypeMap;

import com.winlator.R;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.Comparator;
import java.util.Locale;

public class RootfsDocumentsProvider extends DocumentsProvider {
    private static final String AUTHORITY_SUFFIX = ".rootfs.documents";
    private static final String ROOT_ID_HOME = "home";
    /** 文档 id 分隔: "home" 或 "home/<相对路径>" */
    private static final String ROOT_DOC_ID = ROOT_ID_HOME;
    private static final String MIME_TYPE_BINARY = "application/octet-stream";

    private File baseDir;
    private String basePath = "";

    @Override
    public boolean onCreate() {
        Context context = getContext();
        if (context == null) return false;
        baseDir = new File(context.getFilesDir(), "rootfs/" + ROOT_ID_HOME);
        try {
            basePath = baseDir.getCanonicalPath();
        } catch (IOException e) {
            basePath = baseDir.getAbsolutePath();
        }
        return true;
    }

    private static String authority(Context context) {
        return context.getPackageName() + AUTHORITY_SUFFIX;
    }

    /** 文档 id -> 磁盘真实路径 (强制限制在 baseDir 内, 防止 ../ 逃逸) */
    private File fileForDocId(String docId) throws FileNotFoundException {
        File target;
        if (ROOT_DOC_ID.equals(docId)) {
            target = baseDir;
        } else if (docId.startsWith(ROOT_DOC_ID + "/")) {
            String rel = docId.substring(ROOT_DOC_ID.length() + 1);
            if (rel.contains("..")) throw new FileNotFoundException("非法路径: " + docId);
            target = new File(baseDir, rel);
        } else {
            throw new FileNotFoundException("未知的文档 id: " + docId);
        }
        try {
            String canonical = target.getCanonicalPath();
            if (!canonical.startsWith(baseDir.getCanonicalPath() + File.separator) && !canonical.equals(baseDir.getCanonicalPath())) {
                throw new FileNotFoundException("路径越界: " + docId);
            }
        } catch (IOException e) {
            throw new FileNotFoundException("无法解析路径: " + docId);
        }
        return target;
    }

    String docIdFor(File file) {
        String path;
        try {
            path = file.getCanonicalPath();
        } catch (IOException e) {
            path = file.getAbsolutePath();
        }
        if (basePath.isEmpty() || path.equals(basePath)) return ROOT_DOC_ID;
        return ROOT_DOC_ID + "/" + path.substring(basePath.length() + 1).replace(java.io.File.separatorChar, '/');
    }

    private static String mimeTypeFor(File file) {
        if (file.isDirectory()) return Document.MIME_TYPE_DIR;
        String name = file.getName();
        int dot = name.lastIndexOf('.');
        if (dot >= 0) {
            String ext = name.substring(dot + 1).toLowerCase(Locale.ROOT);
            String mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
            if (mime != null) return mime;
        }
        return MIME_TYPE_BINARY;
    }

    private void includeFile(MatrixCursor cursor, File file) throws FileNotFoundException {
        String docId = docIdFor(file);
        String mime = mimeTypeFor(file);
        MatrixCursor.RowBuilder row = cursor.newRow();
        row.add(Document.COLUMN_DOCUMENT_ID, docId);
        row.add(Document.COLUMN_DISPLAY_NAME, file.getName().isEmpty() ? ROOT_ID_HOME : file.getName());
        row.add(Document.COLUMN_MIME_TYPE, mime);
        row.add(Document.COLUMN_SIZE, file.length());
        row.add(Document.COLUMN_LAST_MODIFIED, file.lastModified());

        int flags = Document.FLAG_SUPPORTS_WRITE | Document.FLAG_SUPPORTS_DELETE |
                    Document.FLAG_SUPPORTS_RENAME | Document.FLAG_SUPPORTS_COPY |
                    Document.FLAG_SUPPORTS_MOVE;
        if (file.isDirectory()) {
            flags |= Document.FLAG_DIR_SUPPORTS_CREATE;
        }
        if (file.canWrite()) {
            row.add(Document.COLUMN_FLAGS, flags);
        } else {
            row.add(Document.COLUMN_FLAGS, flags & ~(Document.FLAG_SUPPORTS_WRITE |
                    Document.FLAG_SUPPORTS_DELETE | Document.FLAG_SUPPORTS_RENAME |
                    Document.FLAG_SUPPORTS_MOVE));
        }
    }

    @Override
    public Cursor queryRoots(String[] projection) throws FileNotFoundException {
        Context context = getContext();
        String authority = authority(context);
        MatrixCursor cursor = new MatrixCursor(projection != null ? projection : resolveRootProjection(projection));
        MatrixCursor.RowBuilder row = cursor.newRow();
        row.add(Root.COLUMN_ROOT_ID, authority + ":" + ROOT_ID_HOME);
        row.add(Root.COLUMN_DOCUMENT_ID, ROOT_DOC_ID);
        row.add(Root.COLUMN_TITLE, "Winlator 容器 Home");
        row.add(Root.COLUMN_SUMMARY, "Wine 容器内 rootfs/home 目录");
        row.add(Root.COLUMN_ICON, R.mipmap.ic_launcher);
        row.add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_CREATE | Root.FLAG_LOCAL_ONLY);
        row.add(Root.COLUMN_MIME_TYPES, "*/*");
        return cursor;
    }

    private static String[] resolveRootProjection(String[] projection) {
        return projection != null ? projection : new String[]{
            Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY, Root.COLUMN_ICON, Root.COLUMN_FLAGS,
            Root.COLUMN_MIME_TYPES, Root.COLUMN_AVAILABLE_BYTES
        };
    }

    @Override
    public Cursor queryDocument(String documentId, String[] projection) throws FileNotFoundException {
        MatrixCursor cursor = new MatrixCursor(projection != null ? projection : new String[]{
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS
        });
        includeFile(cursor, fileForDocId(documentId));
        return cursor;
    }

    @Override
    public Cursor queryChildDocuments(String parentDocumentId, String[] projection, String sortOrder) throws FileNotFoundException {
        MatrixCursor cursor = new MatrixCursor(projection != null ? projection : new String[]{
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS
        });
        File parent = fileForDocId(parentDocumentId);
        File[] children = parent.listFiles();
        if (children == null) {
            if (!parent.isDirectory()) throw new FileNotFoundException("目录不存在: " + parentDocumentId);
            children = new File[0];
        }
        java.util.Arrays.sort(children, new Comparator<File>() {
            @Override
            public int compare(File a, File b) {
                if (a.isDirectory() != b.isDirectory()) return a.isDirectory() ? -1 : 1;
                return a.getName().compareToIgnoreCase(b.getName());
            }
        });
        for (File child : children) includeFile(cursor, child);
        return cursor;
    }

    @Override
    public ParcelFileDescriptor openDocument(String documentId, String mode, CancellationSignal signal) throws FileNotFoundException {
        File file = fileForDocId(documentId);
        int modeBits = ParcelFileDescriptor.parseMode(mode);
        if ((modeBits & ParcelFileDescriptor.MODE_WRITE_ONLY) != 0 && !file.canWrite() && file.exists()) {
            throw new FileNotFoundException("文件不可写: " + documentId);
        }
        if (!file.exists()) {
            try {
                file.getParentFile().mkdirs();
                file.createNewFile();
            } catch (IOException e) {
                throw new FileNotFoundException("无法创建文件: " + documentId);
            }
        }
        return ParcelFileDescriptor.open(file, modeBits);
    }

    @Override
    public AssetFileDescriptor openDocumentThumbnail(String documentId, Point sizeHint, CancellationSignal signal) throws FileNotFoundException {
        File file = fileForDocId(documentId);
        if (file.length() > 4 * 1024 * 1024) return null;
        ParcelFileDescriptor pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
        return new AssetFileDescriptor(pfd, 0, file.length());
    }

    @Override
    public String createDocument(String parentDocumentId, String mimeType, String displayName) throws FileNotFoundException {
        File parent = fileForDocId(parentDocumentId);
        File target = uniqueFile(parent, displayName == null ? "未命名" : displayName);
        try {
            boolean ok = Document.MIME_TYPE_DIR.equals(mimeType) ? target.mkdir() : target.createNewFile();
            if (!ok) throw new FileNotFoundException("创建失败: " + target);
        } catch (IOException e) {
            throw new FileNotFoundException("创建失败: " + e.getMessage());
        }
        return docIdFor(target);
    }

    @Override
    public void deleteDocument(String documentId) throws FileNotFoundException {
        File file = fileForDocId(documentId);
        deleteRecursive(file);
    }

    private static void deleteRecursive(File file) throws FileNotFoundException {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteRecursive(child);
        if (!file.delete() && file.exists()) throw new FileNotFoundException("删除失败: " + file);
    }

    @Override
    public String renameDocument(String documentId, String displayName) throws FileNotFoundException {
        File source = fileForDocId(documentId);
        if (displayName == null || displayName.isEmpty()) throw new FileNotFoundException("名称为空");
        File target = new File(source.getParentFile(), displayName);
        if (target.exists()) throw new FileNotFoundException("同名文件已存在: " + displayName);
        if (!source.renameTo(target)) throw new FileNotFoundException("重命名失败: " + source.getName());
        return docIdFor(target);
    }

    @Override
    public String moveDocument(String sourceDocumentId, String sourceParentDocumentId, String targetParentDocumentId) throws FileNotFoundException {
        File source = fileForDocId(sourceDocumentId);
        File targetParent = fileForDocId(targetParentDocumentId);
        File target = uniqueFile(targetParent, source.getName());
        if (!source.renameTo(target)) throw new FileNotFoundException("移动失败: " + source.getName());
        return docIdFor(target);
    }

    private static File uniqueFile(File dir, String displayName) {
        File target = new File(dir, displayName);
        if (!target.exists()) return target;
        String name = target.getName();
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 2; target.exists(); i++) {
            target = new File(dir, base + " (" + i + ")" + ext);
        }
        return target;
    }
}
