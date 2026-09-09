import 'package:json_annotation/json_annotation.dart';

part 'model_002.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model002 {
  const Model002({required this.id, required this.value});

  final int id;
  final String value;

  factory Model002.fromJson(Map<String, dynamic> json) =>
      _$Model002FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model002ToJson(this);
}
