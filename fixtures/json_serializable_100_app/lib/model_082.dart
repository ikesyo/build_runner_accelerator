import 'package:json_annotation/json_annotation.dart';

part 'model_082.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model082 {
  const Model082({required this.id, required this.value});

  final int id;
  final String value;

  factory Model082.fromJson(Map<String, dynamic> json) =>
      _$Model082FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model082ToJson(this);
}
