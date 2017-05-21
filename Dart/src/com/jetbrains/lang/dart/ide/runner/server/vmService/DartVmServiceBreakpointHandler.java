package com.jetbrains.lang.dart.ide.runner.server.vmService;

import com.intellij.openapi.Disposable;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.util.Computable;
import com.intellij.xdebugger.XDebuggerManager;
import com.intellij.xdebugger.breakpoints.*;
import com.jetbrains.lang.dart.ide.runner.DartExceptionBreakpointProperties;
import com.jetbrains.lang.dart.ide.runner.DartExceptionBreakpointType;
import com.jetbrains.lang.dart.ide.runner.DartLineBreakpointType;
import gnu.trove.THashMap;
import gnu.trove.THashSet;
import org.dartlang.vm.service.element.Breakpoint;
import org.dartlang.vm.service.element.ExceptionPauseMode;
import org.jetbrains.annotations.NotNull;

import java.util.*;

import static com.intellij.icons.AllIcons.Debugger.Db_invalid_breakpoint;
import static com.intellij.icons.AllIcons.Debugger.Db_verified_breakpoint;

public class DartVmServiceBreakpointHandler extends XBreakpointHandler<XLineBreakpoint<XBreakpointProperties>> implements Disposable {
  private final DartVmServiceDebugProcess myDebugProcess;
  private final Set<XLineBreakpoint<XBreakpointProperties>> myXBreakpoints = new THashSet<>();
  private final Map<String, IsolateBreakpointInfo> myIsolateInfo = new THashMap<>();
  private final Map<String, XLineBreakpoint<XBreakpointProperties>> myVmBreakpointIdToXBreakpointMap = new THashMap<>();
  private ExceptionPauseMode myExceptionPauseMode;

  public DartVmServiceBreakpointHandler(@NotNull final DartVmServiceDebugProcess debugProcess) {
    super(DartLineBreakpointType.class);
    myDebugProcess = debugProcess;

    getDebuggerManager().getBreakpointManager().addBreakpointListener(
      DartExceptionBreakpointType.INSTANCE,
      new XBreakpointListener<XBreakpoint<DartExceptionBreakpointProperties>>() {
        @Override
        public void breakpointAdded(@NotNull XBreakpoint<DartExceptionBreakpointProperties> breakpoint) {
          fireOnExceptionModeChange();
        }

        @Override
        public void breakpointChanged(@NotNull XBreakpoint<DartExceptionBreakpointProperties> breakpoint) {
          fireOnExceptionModeChange();
        }

        @Override
        public void breakpointRemoved(@NotNull XBreakpoint<DartExceptionBreakpointProperties> breakpoint) {
          fireOnExceptionModeChange();
        }
      }, this);

    myExceptionPauseMode = getBreakOnExceptionsMode();
  }

  @Override
  public void registerBreakpoint(@NotNull final XLineBreakpoint<XBreakpointProperties> xBreakpoint) {
    myXBreakpoints.add(xBreakpoint);

    final VmServiceWrapper vmServiceWrapper = myDebugProcess.getVmServiceWrapper();
    if (vmServiceWrapper != null) {
      vmServiceWrapper.addBreakpointForIsolates(xBreakpoint, myDebugProcess.getIsolateInfos());
    }
  }

  @Override
  public void unregisterBreakpoint(@NotNull final XLineBreakpoint<XBreakpointProperties> xBreakpoint, boolean temporary) {
    myXBreakpoints.remove(xBreakpoint);

    for (IsolateBreakpointInfo info : myIsolateInfo.values()) {
      info.unregisterBreakpoint(xBreakpoint);
    }
  }

  public Set<XLineBreakpoint<XBreakpointProperties>> getXBreakpoints() {
    return myXBreakpoints;
  }

  public void vmBreakpointAdded(@NotNull final XLineBreakpoint<XBreakpointProperties> xBreakpoint,
                                @NotNull final String isolateId,
                                @NotNull final Breakpoint vmBreakpoint) {
    myVmBreakpointIdToXBreakpointMap.put(vmBreakpoint.getId(), xBreakpoint);

    IsolateBreakpointInfo info = getIsolateInfo(isolateId);
    info.vmBreakpointAdded(xBreakpoint, vmBreakpoint);

    if (vmBreakpoint.getResolved()) {
      breakpointResolved(vmBreakpoint);
    }
  }

  public void temporaryBreakpointAdded(String isolateId, Breakpoint vmBreakpoint) {
    getIsolateInfo(isolateId).temporaryVmBreakpointAdded(vmBreakpoint.getId());
  }

  public void removeTemporaryBreakpoints(String isolateId) {
    getIsolateInfo(isolateId).removeTemporaryBreakpoints();
  }

  public void removeAllVmBreakpoints(@NotNull String isolateId) {
    final Set<String> vmBreakpoints = getIsolateInfo(isolateId).removeAllVmBreakpoints();
    for (String vmBreakpointId : vmBreakpoints) {
      myVmBreakpointIdToXBreakpointMap.remove(vmBreakpointId);
    }
  }

  private IsolateBreakpointInfo getIsolateInfo(String isolateId) {
    IsolateBreakpointInfo info = myIsolateInfo.get(isolateId);
    if (info == null) {
      info = new IsolateBreakpointInfo(isolateId, myDebugProcess);
      myIsolateInfo.put(isolateId, info);
    }
    return info;
  }

  private XDebuggerManager getDebuggerManager() {
    return XDebuggerManager.getInstance(myDebugProcess.getSession().getProject());
  }

  public void breakpointResolved(@NotNull final Breakpoint vmBreakpoint) {
    final XLineBreakpoint<XBreakpointProperties> xBreakpoint = myVmBreakpointIdToXBreakpointMap.get(vmBreakpoint.getId());

    // This can be null when the breakpoint has been set by another debugger client.
    if (xBreakpoint != null) {
      myDebugProcess.getSession().updateBreakpointPresentation(xBreakpoint, Db_verified_breakpoint, null);
    }
  }

  public void breakpointFailed(@NotNull final XLineBreakpoint<XBreakpointProperties> xBreakpoint) {
    // can this xBreakpoint be resolved for other isolate?
    myDebugProcess.getSession().updateBreakpointPresentation(xBreakpoint, Db_invalid_breakpoint, null);
  }

  public XLineBreakpoint<XBreakpointProperties> getXBreakpoint(@NotNull final Breakpoint vmBreakpoint) {
    return myVmBreakpointIdToXBreakpointMap.get(vmBreakpoint.getId());
  }

  public ExceptionPauseMode getBreakOnExceptionsMode() {
    XBreakpoint<DartExceptionBreakpointProperties> bp = getExceptionBreakpoint();

    if (bp == null) {
      // Default to breaking on unhandled exceptions.
      return ExceptionPauseMode.Unhandled;
    }

    if (!bp.isEnabled()) {
      return ExceptionPauseMode.None;
    }
    else if (bp.getProperties().breakOnAllExceptions()) {
      return ExceptionPauseMode.All;
    }
    else {
      return ExceptionPauseMode.Unhandled;
    }
  }

  private XBreakpoint<DartExceptionBreakpointProperties> getExceptionBreakpoint() {
    return ApplicationManager.getApplication().runReadAction((Computable<XBreakpoint<DartExceptionBreakpointProperties>>)() -> {
      Collection<? extends XBreakpoint<DartExceptionBreakpointProperties>>
        exceptionBreakpoints =
        getDebuggerManager().getBreakpointManager().getBreakpoints(DartExceptionBreakpointType.class);
      return exceptionBreakpoints.isEmpty() ? null : exceptionBreakpoints.iterator().next();
    });
  }

  @Override
  public void dispose() {
    // This class implements Disposable in order to be able to pass itself into
    // BreakpointManager.addBreakpointListener() as the parentDisposable.
  }

  private void fireOnExceptionModeChange() {
    ExceptionPauseMode newMode = getBreakOnExceptionsMode();

    if (newMode != myExceptionPauseMode) {
      myExceptionPauseMode = newMode;

      myDebugProcess.setExceptionPauseMode(newMode);
    }
  }
}

class IsolateBreakpointInfo {
  private final String myIsolateId;
  private final DartVmServiceDebugProcess myDebugProcess;
  private final List<String> myTemporaryVmBreakpointIds = new ArrayList<>();
  private final Map<XLineBreakpoint<XBreakpointProperties>, Set<String>> myXBreakpointToVmBreakpointIdsMap = new THashMap<>();

  IsolateBreakpointInfo(@NotNull String isolateId, @NotNull DartVmServiceDebugProcess debugProcess) {
    this.myIsolateId = isolateId;
    this.myDebugProcess = debugProcess;
  }

  public void removeTemporaryBreakpoints() {
    for (String breakpointId : myTemporaryVmBreakpointIds) {
      myDebugProcess.getVmServiceWrapper().removeBreakpoint(myIsolateId, breakpointId);
    }
    myTemporaryVmBreakpointIds.clear();
  }

  public Set<String> removeAllVmBreakpoints() {
    if (!myDebugProcess.isIsolateAlive(myIsolateId)) {
      return new HashSet<>();
    }

    final Set<String> allVmBreakpoints = new HashSet<>();

    synchronized (myXBreakpointToVmBreakpointIdsMap) {
      for (Set<String> bps : myXBreakpointToVmBreakpointIdsMap.values()) {
        allVmBreakpoints.addAll(bps);
      }
      myXBreakpointToVmBreakpointIdsMap.clear();
    }

    for (String vmBreakpointId : allVmBreakpoints) {
      myDebugProcess.getVmServiceWrapper().removeBreakpoint(myIsolateId, vmBreakpointId);
    }

    return allVmBreakpoints;
  }

  public void temporaryVmBreakpointAdded(String vmBreakpointId) {
    myTemporaryVmBreakpointIds.add(vmBreakpointId);
  }

  public void vmBreakpointAdded(XLineBreakpoint<XBreakpointProperties> xBreakpoint, Breakpoint vmBreakpoint) {
    getVmBreakpoints(xBreakpoint).add(vmBreakpoint.getId());
  }

  public void unregisterBreakpoint(XLineBreakpoint<XBreakpointProperties> xBreakpoint) {
    if (myDebugProcess.isIsolateAlive(myIsolateId)) {
      for (String vmBreakpointId : getVmBreakpoints(xBreakpoint)) {
        myDebugProcess.getVmServiceWrapper().removeBreakpoint(myIsolateId, vmBreakpointId);
      }
    }

    myXBreakpointToVmBreakpointIdsMap.remove(xBreakpoint);
  }

  private Set<String> getVmBreakpoints(XLineBreakpoint<XBreakpointProperties> xBreakpoint) {
    synchronized (myXBreakpointToVmBreakpointIdsMap) {
      Set<String> vmBreakpoints = myXBreakpointToVmBreakpointIdsMap.get(xBreakpoint);
      if (vmBreakpoints == null) {
        vmBreakpoints = new HashSet<>();
        myXBreakpointToVmBreakpointIdsMap.put(xBreakpoint, vmBreakpoints);
      }
      return vmBreakpoints;
    }
  }
}
