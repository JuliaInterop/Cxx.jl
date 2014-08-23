using CXX

@osx_only begin
    const qtlibdir = "/Users/kfischer/Projects/qt-everywhere-opensource-src-5.3.1/qtbase/~/usr/lib/"
    const QtCore = joinpath(qtlibdir,"QtCore.framework/")
    const QtWidgets = joinpath(qtlibdir,"QtWidgets.framework/")

    addHeaderDir(qtlibdir; isFramework = true, kind = C_System)

    dlopen(joinpath(QtCore,"QtCore_debug"))
    addHeaderDir(joinpath(QtCore,"Headers"), kind = C_System)
    addHeaderDir("/Users/kfischer/Projects/qt-everywhere-opensource-src-5.3.1/qtbase/lib/QtCore.framework/Headers/5.3.1/QtCore")

    cxxinclude("/Users/kfischer/Projects/qt-everywhere-opensource-src-5.3.1/qtbase/lib/QtCore.framework/Headers/5.3.1/QtCore/private/qcoreapplication_p.h")

    dlopen(joinpath(QtWidgets,"QtWidgets"))
    addHeaderDir(joinpath(QtWidgets,"Headers"), kind = C_System)
end

@linux_only begin
    const qtincdir = "/usr/include/qt5"
    const qtlibdir = "/usr/lib/x86_64-linux-gnu/"

    addHeaderDir(qtincdir, kind = C_System)
    addHeaderDir(QtWidgets, kind = C_System)

    dlopen(joinpath(qtlibdir,"libQt5Core.so"), RTLD_GLOBAL)
    dlopen(joinpath(qtlibdir,"libQt5Gui.so"), RTLD_GLOBAL)
    dlopen(joinpath(qtlibdir,"libQt5Widgets.so"), RTLD_GLOBAL)
end

cxxinclude("QApplication", isAngled=true)
cxxinclude("QMessageBox", isAngled=true)

const a = "julia"
x = Ptr{Uint8}[pointer(a),C_NULL]
# This is pretty stupid, but it seems QApplication is capturing the pointer to the reference, so we can't just
# stack allocate it because that won't be valid for exec
ac = [int32(1)]
app = @cxx QApplication(*(pointer(ac)),pointer(x))

@cxx QMessageBox::about(cast(C_NULL,pcpp"QWidget"), pointer("Hello World"), pointer("This is a QMessageBox!"))

@cxx app->exec()