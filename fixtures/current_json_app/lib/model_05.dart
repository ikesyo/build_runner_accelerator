import 'package:json_annotation/json_annotation.dart';

part 'model_05.g.dart';

@JsonSerializable()
class Model05 {
  Model05({required this.id, required this.displayName});

  factory Model05.fromJson(Map<String, dynamic> json) =>
      _$Model05FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model05ToJson(this);
}

// baseline-marker: base
