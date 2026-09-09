import 'package:json_annotation/json_annotation.dart';

part 'model_312.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model312 {
  const Model312({required this.id, required this.value});

  final int id;
  final String value;

  factory Model312.fromJson(Map<String, dynamic> json) =>
      _$Model312FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model312ToJson(this);
}
