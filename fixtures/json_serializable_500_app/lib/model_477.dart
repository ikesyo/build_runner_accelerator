import 'package:json_annotation/json_annotation.dart';

part 'model_477.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model477 {
  const Model477({required this.id, required this.value});

  final int id;
  final String value;

  factory Model477.fromJson(Map<String, dynamic> json) =>
      _$Model477FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model477ToJson(this);
}
