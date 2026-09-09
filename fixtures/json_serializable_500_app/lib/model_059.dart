import 'package:json_annotation/json_annotation.dart';

part 'model_059.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model059 {
  const Model059({required this.id, required this.value});

  final int id;
  final String value;

  factory Model059.fromJson(Map<String, dynamic> json) =>
      _$Model059FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model059ToJson(this);
}
