import 'package:json_annotation/json_annotation.dart';

part 'model_325.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model325 {
  const Model325({required this.id, required this.value});

  final int id;
  final String value;

  factory Model325.fromJson(Map<String, dynamic> json) =>
      _$Model325FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model325ToJson(this);
}
