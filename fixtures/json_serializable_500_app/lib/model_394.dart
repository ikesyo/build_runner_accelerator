import 'package:json_annotation/json_annotation.dart';

part 'model_394.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model394 {
  const Model394({required this.id, required this.value});

  final int id;
  final String value;

  factory Model394.fromJson(Map<String, dynamic> json) =>
      _$Model394FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model394ToJson(this);
}
