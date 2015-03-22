using Cxx

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

    const QtWidgets = joinpath(qtincdir, "QtWidgets/")

    addHeaderDir(qtincdir, kind = C_System)
    addHeaderDir(QtWidgets, kind = C_System)

    dlopen(joinpath(qtlibdir,"libQt5Core.so"), RTLD_GLOBAL)
    dlopen(joinpath(qtlibdir,"libQt5Gui.so"), RTLD_GLOBAL)
    dlopen(joinpath(qtlibdir,"libQt5Widgets.so"), RTLD_GLOBAL)
end

cxxinclude("QApplication", isAngled=true)
cxxinclude("QMessageBox", isAngled=true)
cxxinclude("QPushButton", isAngled=true)

const a = "julia"
x = Ptr{UInt8}[pointer(a),C_NULL]
# This is pretty stupid, but it seems QApplication is capturing the pointer
# to the reference, so we can't just # stack allocate it because that won't
# be valid for exec
ac = [int32(1)]

app = @cxx QApplication(*(pointer(ac)),pointer(x))

# BUG: this version doesn't work - unresponsive gui
#update_loop(_timer) = @cxx app.processEvents() # default QEventFlags::AllEvents

# create messagebox
mb = @cxxnew QMessageBox(@cxx(QMessageBox::Information),
                      pointer("Hello World"),
                      pointer("This is a QMessageBox"))

# add buttons
@cxx mb->addButton(@cxx(QMessageBox::Ok))

hibtn = @cxxnew QPushButton(pointer("Say Hi!"))
@cxx mb->addButton(hibtn, @cxx(QMessageBox::ApplyRole))

say_hi() = println("Hi!")::Void
cxx"""
#include <iostream>
void handle_hi()
{
    $:(say_hi());
}
"""

# BUGS?
# - type translation doesn't work right for $:(btn) if I call connect from a cxx""" block
# - I get isexprs assertion failure if I try to use a lambda. think it might be a
#   block parsing issue though.
function setup(btn)
    icxx"""
        QObject::connect($btn, &QPushButton::clicked,
            handle_hi );
    """
end
setup(hibtn)

# display the window
@cxx mb->setWindowModality(@cxx(Qt::NonModal))
@cxx mb->show()

# start event loop integration
function update_loop(_timer)
    icxx"""
        $app.processEvents();
    """
end

timer = Base.Timer( update_loop )
Base.start_timer(timer, .1, .005)

# exit if not interactive shell
!isinteractive() && stop_timer(timer)
