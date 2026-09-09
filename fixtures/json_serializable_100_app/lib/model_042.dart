import 'package:json_annotation/json_annotation.dart';

part 'model_042.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model042 {
  const Model042({required this.id, required this.value});

  final int id;
  final String value;

  factory Model042.fromJson(Map<String, dynamic> json) =>
      _$Model042FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model042ToJson(this);
}
