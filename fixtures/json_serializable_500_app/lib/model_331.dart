import 'package:json_annotation/json_annotation.dart';

part 'model_331.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model331 {
  const Model331({required this.id, required this.value});

  final int id;
  final String value;

  factory Model331.fromJson(Map<String, dynamic> json) =>
      _$Model331FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model331ToJson(this);
}
